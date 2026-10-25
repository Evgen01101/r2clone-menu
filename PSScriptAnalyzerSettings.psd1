@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSAvoidUsingPositionalParameters'
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
