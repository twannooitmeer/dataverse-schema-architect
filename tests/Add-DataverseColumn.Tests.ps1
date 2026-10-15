#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Request-body tests for Add-DataverseColumn's numeric bounds. No Dataverse
    environment is involved: Test-DataverseColumn and Invoke-DataverseApi are
    mocked inside the module, and each test asserts on the body that would
    have been POSTed.

    Regression for 2026-10-15 (found in a client deployment): an Integer column deployed
    from a spec without minValue/maxValue was created with MinValue 0 and
    MaxValue 0, because the unset [int] parameters were always sent.

    Run: Invoke-Pester ./tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'skills' 'deploy-dataverse-schema' 'scripts' 'Dataverse.psm1') -Force

    $script:common = @{
        EntityLogicalName  = 'contoso_processlog'
        DisplayName        = 'Attempt'
        SolutionUniqueName = 'ContosoGeneric'
    }
}

Describe 'Add-DataverseColumn numeric bounds' {
    BeforeEach {
        Mock -ModuleName Dataverse Test-DataverseColumn { $false }
        Mock -ModuleName Dataverse Invoke-DataverseApi { }
        Mock -ModuleName Dataverse Write-Host { }
    }

    Context 'Integer' {
        It 'sends no MinValue or MaxValue when the caller passed neither' {
            Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                -not $Body.ContainsKey('MinValue') -and -not $Body.ContainsKey('MaxValue') -and
                ($Body | ConvertTo-Json -Depth 20) -notmatch 'MinValue|MaxValue'
            }
        }

        It 'sends both bounds as whole numbers when the caller passed both' {
            Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer -MinValue 1 -MaxValue 10

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.MinValue -is [int] -and $Body.MinValue -eq 1 -and
                $Body.MaxValue -is [int] -and $Body.MaxValue -eq 10
            }
        }

        It 'sends an explicit 0 and leaves the other bound out' {
            Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer -MinValue 0

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.ContainsKey('MinValue') -and $Body.MinValue -eq 0 -and -not $Body.ContainsKey('MaxValue')
            }
        }

        It 'rejects a fractional bound before calling the API' {
            { Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer -MinValue 1.5 } | Should -Throw '*not a whole number*'
            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 0 -Exactly
        }

        It 'rejects a bound outside the Int32 range before calling the API' {
            { Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer -MaxValue 3000000000 } | Should -Throw '*outside the supported Integer range*'
            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 0 -Exactly
        }
    }

    Context 'Decimal and Money' {
        It 'sends the full Decimal range when the caller passed no bounds' {
            Add-DataverseColumn @common -SchemaName 'contoso_score' -Type Decimal

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.MinValue -eq -100000000000 -and $Body.MaxValue -eq 100000000000 -and $Body.Precision -eq 2
            }
        }

        It 'sends the full Money range when the caller passed no bounds' {
            Add-DataverseColumn @common -SchemaName 'contoso_amount' -Type Money

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.MinValue -eq -922337203685477 -and $Body.MaxValue -eq 922337203685477
            }
        }

        It 'sends fractional Decimal bounds the caller passed' {
            Add-DataverseColumn @common -SchemaName 'contoso_score' -Type Decimal -MinValue -5.5 -MaxValue 5.5

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.MinValue -eq -5.5 -and $Body.MaxValue -eq 5.5
            }
        }

        It 'keeps the default for the bound the caller did not pass' {
            Add-DataverseColumn @common -SchemaName 'contoso_amount' -Type Money -MinValue 0

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 1 -Exactly -ParameterFilter {
                $Body.MinValue -eq 0 -and $Body.MaxValue -eq 922337203685477
            }
        }
    }

    Context 'invalid combinations' {
        It 'rejects bounds on a non-numeric column' {
            { Add-DataverseColumn @common -SchemaName 'contoso_name' -Type String -MinValue 1 } | Should -Throw '*only apply to Integer, Decimal and Money*'
            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 0 -Exactly
        }

        It 'rejects MinValue greater than MaxValue' {
            { Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer -MinValue 10 -MaxValue 1 } | Should -Throw '*greater than -MaxValue*'
            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 0 -Exactly
        }
    }

    Context 'existing column' {
        It 'skips without validating or creating anything' {
            Mock -ModuleName Dataverse Test-DataverseColumn { $true }
            Mock -ModuleName Dataverse Test-DataverseColumnDrift { }

            Add-DataverseColumn @common -SchemaName 'contoso_attempt' -Type Integer

            Should -Invoke -ModuleName Dataverse Invoke-DataverseApi -Times 0 -Exactly
        }
    }
}
