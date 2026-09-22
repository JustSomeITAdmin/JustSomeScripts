#
# Module manifest for 'PSAppDeployToolkit.Extensions' - the OpenDriverUpdater control plane.
# The launcher's Invocation block imports this folder BY THIS MANIFEST, so it must exist alongside the .psm1.
#

@{
    # Script module file associated with this manifest (the OpenDriverUpdater helper functions).
    RootModule        = 'PSAppDeployToolkit.Extensions.psm1'

    ModuleVersion     = '1.0.0'
    Guid              = '998eb938-574f-4d3d-8bb2-57d1feca0a33'
    Description       = 'OpenDriverUpdater extensions for PSAppDeployToolkit (driver-update control plane).'

    PowerShellVersion = '5.1.14393.0'
    CLRVersion        = '4.0.30319.42000'

    # PSAppDeployToolkit 4.2 must be loaded first; the launcher imports it before this module.
    RequiredModules   = @(
        @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' }
    )

    # Export everything (the Get/Set/Test/Invoke/Register/Resolve-ODU* helpers) - wildcard, so no list to maintain.
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{ PSData = @{} }
}
