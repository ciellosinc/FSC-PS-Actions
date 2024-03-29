Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "DynamicsVersion", Mandatory = $false)]
    [string] $DynamicsVersion,
    [Parameter(HelpMessage = "Environment name o deploy", Mandatory = $false)]
    [string] $EnvironmentName,
    [Parameter(HelpMessage = "Settings from repository in compressed Json format", Mandatory = $false)]
    [string] $settingsJson = '',
    [Parameter(HelpMessage = "Secrets from repository in compressed Json format", Mandatory = $false)]
    [string] $secretsJson = ''
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
# IMPORTANT: No code that can fail should be outside the try/catch


try {
    $helperPath = Join-Path -Path $PSScriptRoot -ChildPath "..\FSC-PS-Helper.ps1" -Resolve
    . ($helperPath)
    
    $LastExitCode = 0
    $baseFolder = $ENV:GITHUB_WORKSPACE
    $workflowName = $env:GITHUB_WORKFLOW
    $github = (Get-ActionContext)

    #Use settings and secrets
    Write-Output "::group::Use settings and secrets"
    OutputInfo "======================================== Use settings and secrets"

    $settings = $settingsJson | ConvertFrom-Json | ConvertTo-HashTable | ConvertTo-OrderedDictionary
    $secrets = $secretsJson | ConvertFrom-Json | ConvertTo-HashTable
    $settingsHash = $settings #| ConvertTo-HashTable
    $settings.secretsList | ForEach-Object {
        $setValue = ""
        if($settingsHash.Contains($_))
        {
            $setValue = $settingsHash."$_"
        }
        if ($secrets.ContainsKey($setValue)) 
        {
            OutputInfo "Found $($_) variable in the settings file with value: ($setValue)"
            $value = $secrets."$setValue"
        }
        else {
            $value = "test"
        }
        Set-Variable -Name $_ -Value $value
    }
    
    if($DynamicsVersion -eq "")
    {
        $DynamicsVersion = $settings.buildVersion
    }

    installModules @("AZ.Storage","d365fo.tools")

    $version = Get-VersionData -sdkVersion $DynamicsVersion

    if($settings.sourceBranch -eq "")
    {
        $settings.sourceBranch = $settings.currentBranch
    }
    $settings
    $version
    #SourceBranchToPascakCase
    $settings.sourceBranch = [regex]::Replace(($settings.sourceBranch).Replace("refs/heads/","").Replace("/","_"), '(?i)(?:^|-|_)(\p{L})', { $args[0].Groups[1].Value.ToUpper() })
    $buildPath = Join-Path "C:\Temp" $settings.buildPath
    $PlatformVersion = $version.PlatformVersion
    $ApplicationVersion = $version.AppVersion

    $tools_package =  'Microsoft.Dynamics.AX.Platform.CompilerPackage.' + $PlatformVersion
    $plat_package =  'Microsoft.Dynamics.AX.Platform.DevALM.BuildXpp.' + $PlatformVersion
    $app_package =  'Microsoft.Dynamics.AX.Application.DevALM.BuildXpp.' + $ApplicationVersion
    $appsuite_package =  'Microsoft.Dynamics.AX.ApplicationSuite.DevALM.BuildXpp.' + $ApplicationVersion
    ##get main model
    $mainModel = Get-FSCModels -metadataPath $settings.metadataPath

    ### Init
    $initCustomScript = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\CustomScripts\Init.ps1'
    if(Test-Path $initCustomScript)
    {
        & $initCustomScript -settings $settings -githubContext $github -helperPath $helperPath -token $repoTokenSecretName
    }
    ### Init

    # GetModels
    if($($settings.specifyModelsManually) -eq "true")
    {
        $mtdtdPath = ("$($buildPath)\$($settings.metadataPath)".Trim())
        $mdls = $($settings.models).Split(",")
        if($($settings.includeTestModel) -eq "true")
        {
            $testModels = Get-AXReferencedTestModel -modelNames $($mdls -join ",") -metadataPath $mtdtdPath
            ($testModels.Split(",").ForEach({$mdls+=($_)}))
        }
        $models = $mdls -join ","
        $modelsToPackage = $models
    }
    else {
        $models = Get-FSCModels -metadataPath $settings.metadataPath -includeTest:($settings.includeTestModel -eq 'true')
        $modelsToPackage = Get-FSCModels -metadataPath $settings.metadataPath -includeTest:($settings.includeTestModel -eq 'true') -all
    }
    

    
    Write-Output "Main model: $mainModel"
    Write-Output "Models: $models"
    Write-Output "Models to package: $modelsToPackage"

    Write-Output "::endgroup::"
    #Generate solution folder
    Write-Output "::group::Generate solution folder"
    OutputInfo "======================================== Generate solution folder"
    GenerateSolution -ModelName $models -NugetFeedName $settings.nugetFeedName -NugetSourcePath $settings.nugetSourcePath -DynamicsVersion $DynamicsVersion -MetadataPath (Join-Path $baseFolder $settings.metadataPath)
    Write-Output "::endgroup::"

    Write-Output "::group::Cleanup Build folder"
    OutputInfo "======================================== Cleanup Build folder"
    #Cleanup Build folder
    Remove-Item $buildPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "::endgroup::"

    Write-Output "::group::Copy branch files"
    OutputInfo "======================================== Copy branch files"
    #Copy branch files
    New-Item -ItemType Directory -Force -Path $buildPath; Copy-Item $ENV:GITHUB_WORKSPACE\* -Destination $buildPath -Recurse -Force
    Write-Output "::endgroup::"

    Write-Output "::group::Copy solution folder"
    OutputInfo "======================================== Copy solution folder"
    #Copy solution folder
    Copy-Item NewBuild -Destination $buildPath -Recurse -Force
    Write-Output "::endgroup::"

    if($settings.nugetFeedName)
    {
        Write-Output "::group::Cleanup NuGet"
        OutputInfo "======================================== Cleanup NuGet"
        #Cleanup NuGet
        nuget sources remove -Name $settings.nugetFeedName -Source $settings.nugetSourcePath
        Write-Output "::endgroup::"
    }

    if($settings.useLocalNuGetStorage)
    {
        Write-Output "::group::Download default NuGet packages"
        OutputInfo "======================================== Download default NuGet"

        Update-FSCNuGet -sdkVersion $settings.buildVersion
        Write-Output "::endgroup::"
    }

    if($settings.nugetFeedName)
    {
        Write-Output "::group::Nuget add source"
        OutputInfo "======================================== Nuget add source"
        #Nuget add source
        nuget sources Add -Name $settings.nugetFeedName -Source $settings.nugetSourcePath -username $nugetFeedUserSecretName -password $nugetFeedPasswordSecretName       
        Write-Output "::endgroup::"
    }

    Write-Output "::group::Nuget install packages"
    OutputInfo "======================================== Nuget install packages"
    $packagesFilePath = Join-Path $buildPath NewBuild\packages.config
    if(Test-Path $packagesFilePath)
    {
        OutputInfo "Found packages.config file at path: $packagesFilePath "
    }
    else
    {
        OutputInfo "Not Found packages.config file at path: $packagesFilePath "
    }
    
    Set-Location $buildPath
    Set-Location NewBuild
    #Nuget install packages
    nuget restore -PackagesDirectory ..\NuGets
    Write-Output "::endgroup::"

    Write-Output "::group::Copy dll`s to build folder"
    #Copy dll`s to build folder
    OutputInfo "======================================== Copy dll`s to build folder"
    OutputInfo "Source path: (Join-Path $($buildPath) $($settings.metadataPath))"
    OutputInfo "Destination path: (Join-Path $($buildPath) bin)"

    Copy-Filtered -Source (Join-Path $($buildPath) $($settings.metadataPath)) -Target (Join-Path $($buildPath) bin) -Filter *.*
    Write-Output "::endgroup::"

    Write-Output "::group::Build solution"
    #Build solution
    OutputInfo "======================================== Build solution"
    Set-Location $buildPath
    
    ### Prebuild
    $prebuildCustomScript = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\CustomScripts\PreBuild.ps1'
    if(Test-Path $prebuildCustomScript)
    {
        & $prebuildCustomScript -settings $settings -githubContext $github -helperPath $helperPath
    }
    ### Prebuild

    $msReferenceFolder = "$($buildPath)\$($settings.nugetPackagesPath)\$($app_package)\ref\net40;$($buildPath)\$($settings.nugetPackagesPath)\$plat_package\ref\net40;$($buildPath)\$($settings.nugetPackagesPath)\$appsuite_package\ref\net40;$($buildPath)\$($settings.metadataPath);$($buildPath)\bin"
    $msBuildTasksDirectory = "$($buildPath)\$($settings.nugetPackagesPath)\$tools_package\DevAlm".Trim()
    $msMetadataDirectory = "$($buildPath)\$($settings.metadataPath)".Trim()
    $msFrameworkDirectory = "$($buildPath)\$($settings.nugetPackagesPath)\$tools_package".Trim()
    $msReferencePath = "$($buildPath)\$($settings.nugetPackagesPath)\$tools_package".Trim()
    $msOutputDirectory = "$($buildPath)\bin".Trim()

    $buidPropsFile = Join-Path $buildPath NewBuild\Build\build.props
    $tempFile = (Get-Content $buidPropsFile).Replace('ReferenceFolders', $msReferenceFolder)
    Set-Content $buidPropsFile $tempFile

    if($workflowName -eq "(RELEASE)")
    {
        if($($github.Payload.inputs.versionNumber) -ne "")
        {
            if($models.Split(","))
            {
                if($mainModel.Split(","))
                {
                    Update-FSCModelVersion -xppSourcePath $msMetadataDirectory -xppLayer "ISV" -versionNumber $($github.Payload.inputs.versionNumber) -xppDescriptorSearch $($($mainModel.Split(",").Item(0))+"\Descriptor\*.xml")
                }
                else {
                    Update-FSCModelVersion -xppSourcePath $msMetadataDirectory -xppLayer "ISV" -versionNumber $($github.Payload.inputs.versionNumber) -xppDescriptorSearch $($mainModel+"\Descriptor\*.xml")
                }
            }
            else {
                Update-FSCModelVersion -xppSourcePath $msMetadataDirectory -xppLayer "ISV" -versionNumber $($github.Payload.inputs.versionNumber) -xppDescriptorSearch $($models+"\Descriptor\*.xml")
            }
        }
    }
    installModules "Invoke-MsBuild"

    $msbuildresult = Invoke-MsBuild -Path "NewBuild\Build\Build.sln" -P "/p:BuildTasksDirectory=$msBuildTasksDirectory /p:MetadataDirectory=$msMetadataDirectory /p:FrameworkDirectory=$msFrameworkDirectory /p:ReferencePath=$msReferencePath /p:OutputDirectory=$msOutputDirectory" -ShowBuildOutputInCurrentWindow

    if ($msbuildresult.BuildSucceeded -eq $true)
    {
      Write-Output ("Build completed successfully in {0:N1} seconds." -f $msbuildresult.BuildDuration.TotalSeconds)
    }
    elseif ($msbuildresult.BuildSucceeded -eq $false)
    {
      Write-Error ("Build failed after {0:N1} seconds. Check the build log file '$($msbuildresult.BuildLogFilePath)' for errors." -f $msbuildresult.BuildDuration.TotalSeconds)
    }
    elseif ($null -eq $msbuildresult.BuildSucceeded)
    {
      Write-Error "Unsure if build passed or failed: $($msbuildresult.Message)"
    }


    ### Postbuild
    $postbuildCustomScript = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\CustomScripts\PostBuild.ps1'
    if(Test-Path $postbuildCustomScript)
    {
        & $postbuildCustomScript -settings $settings -githubContext $github -helperPath $helperPath
    }
    ### Postbuild
    
    Write-Output "::endgroup::"

    #GeneratePackages
    if($settings.generatePackages)
    {
        Write-Output "::group::Generate packages"
        OutputInfo "======================================== Generate packages"

        $packageNamePattern = $settings.packageNamePattern;

        $packageNamePattern = $packageNamePattern.Replace("BRANCHNAME", $($settings.sourceBranch))
        if($settings.deploy)
        {
            $packageNamePattern = $packageNamePattern.Replace("PACKAGENAME", $EnvironmentName)
        }
        else
        {
            $packageNamePattern = $packageNamePattern.Replace("PACKAGENAME", $settings.packageName)
        }
        $packageNamePattern = $packageNamePattern.Replace("FNSCMVERSION", $DynamicsVersion)
        $packageNamePattern = $packageNamePattern.Replace("DATE", (Get-Date -Format "yyyyMMdd").ToString())
        $packageNamePattern = $packageNamePattern.Replace("RUNNUMBER", $ENV:GITHUB_RUN_NUMBER)
        $packageName = $packageNamePattern + ".zip"

        $xppToolsPath = $msFrameworkDirectory
        $xppBinariesPath = (Join-Path $($buildPath) bin)
        $xppBinariesSearch = $modelsToPackage
        $deployablePackagePath = Join-Path (Join-Path $buildPath $settings.artifactsPath) ($packageName)

        if ($xppBinariesSearch.Contains(","))
        {
            [string[]]$xppBinariesSearch = $xppBinariesSearch -split ","
        }

        $potentialPackages = Find-Match -DefaultRoot $xppBinariesPath -Pattern $xppBinariesSearch | Where-Object { (Test-Path -LiteralPath $_ -PathType Container) }
        $packages = @()
        if ($potentialPackages.Length -gt 0)
        {
            OutputInfo "Found $($potentialPackages.Length) potential folders to include:"
            foreach($package in $potentialPackages)
            {
                $packageBinPath = Join-Path -Path $package -ChildPath "bin"
                
                # If there is a bin folder and it contains *.MD files, assume it's a valid X++ binary
                try {
                    if ((Test-Path -Path $packageBinPath) -and ((Get-ChildItem -Path $packageBinPath -Filter *.md).Count -gt 0))
                    {
                        Write-Output $packageBinPath
                        OutputInfo "  - $package"
                        $packages += $package
                    }
                }
                catch
                {
                    Write-Output "  - $package (not an X++ binary folder, skip)"
                }
            }

            $artifactDirectory = [System.IO.Path]::GetDirectoryName($deployablePackagePath)
            if (!(Test-Path -Path $artifactDirectory))
            {
                # The reason to use System.IO.Directory.CreateDirectory is it creates any directories missing in the whole path
                # whereas New-Item would only create the top level directory
                [System.IO.Directory]::CreateDirectory($artifactDirectory)
            }

            Import-Module (Join-Path -Path $xppToolsPath -ChildPath "CreatePackage.psm1")
            $outputDir = Join-Path -Path $buildPath -ChildPath ((New-Guid).ToString())
            $tempCombinedPackage = Join-Path -Path $buildPath -ChildPath "$((New-Guid).ToString()).zip"
            try
            {
                New-Item -Path $outputDir -ItemType Directory > $null
                OutputInfo "Creating binary packages"
                Import-D365FSCMetadataAssemblies $xppToolsPath -Verbose
                foreach($packagePath in $packages)
                {
                    $packageName = (Get-Item $packagePath).Name
                    OutputInfo "  - '$packageName'"
                    $version = ""
                    $packageDll = Join-Path -Path $packagePath -ChildPath "bin\Dynamics.AX.$packageName.dll"
                    if (Test-Path $packageDll)
                    {
                        $version = (Get-Item $packageDll).VersionInfo.FileVersion
                    }
                    if (!$version)
                    {
                        $version = "1.0.0.0"
                    }
                    New-XppRuntimePackage -packageName $packageName -packageDrop $packagePath -outputDir $outputDir -metadataDir $xppBinariesPath -packageVersion $version -binDir $xppToolsPath -enforceVersionCheck $True
                }

                OutputInfo "Creating deployable package"
                Add-Type -Path "$xppToolsPath\Microsoft.Dynamics.AXCreateDeployablePackageBase.dll"
                OutputInfo "  - Creating combined metadata package"
                [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::CreateMetadataPackage($outputDir, $tempCombinedPackage)
                OutputInfo "  - Creating merged deployable package"
                [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::MergePackage("$xppToolsPath\BaseMetadataDeployablePackage.zip", $tempCombinedPackage, $deployablePackagePath, $true, [String]::Empty)
                OutputInfo "Deployable package '$deployablePackagePath' successfully created."

                $pname = ($deployablePackagePath.SubString("$deployablePackagePath".LastIndexOf('\') + 1)).Replace(".zip","")
              
                if($settings.exportModel)
                {
                    Write-Output "::group::Export axmodel file"
                    $models
                    if($models.Split(","))
                    {
                        
                        $models.Split(",") | ForEach-Object{
                            OutputInfo "Exporting $_ model..."
                            $modelFilePath = Export-D365Model -Path $artifactDirectory -Model (Get-AXModelName -ModelName $_ -ModelPath $msMetadataDirectory)  -BinDir $msFrameworkDirectory -MetaDataDir $msMetadataDirectory
                            $modelFile = Get-Item $modelFilePath.File
                            Rename-Item $modelFile.FullName (($_)+($modelFile.Extension)) -Force
                        }
                    }
                    else {
                        OutputInfo "Exporting $models model..."
                        $modelFilePath = Export-D365Model -Path $artifactDirectory -Model (Get-AXModelName -ModelName $models -ModelPath $msMetadataDirectory) -BinDir $msFrameworkDirectory -MetaDataDir $msMetadataDirectory
                        $modelFile = Get-Item $modelFilePath.File
                        Rename-Item $modelFile.FullName (($models)+($modelFile.Extension)) -Force
                    }
                    Write-Output "::endgroup::"
                }

                Add-Content -Path $env:GITHUB_OUTPUT -Value "PACKAGE_NAME=$pname"
                Add-Content -Path $env:GITHUB_ENV -Value "PACKAGE_NAME=$pname"
                Add-Content -Path $env:GITHUB_OUTPUT -Value "PACKAGE_PATH=$deployablePackagePath"
                Add-Content -Path $env:GITHUB_ENV -Value "PACKAGE_PATH=$deployablePackagePath"
                Add-Content -Path $env:GITHUB_OUTPUT -Value "ARTIFACTS_PATH=$artifactDirectory"
                Add-Content -Path $env:GITHUB_ENV -Value "ARTIFACTS_PATH=$artifactDirectory"


                $artifacts = Get-ChildItem $artifactDirectory
                $artifactsList = $artifacts.FullName -join ","

                if($artifactsList.Contains(','))
                {
                    $artifacts = $artifactsList.Split(',') | ConvertTo-Json -compress
                }
                else
                {
                    $artifacts = '["'+$($artifactsList).ToString()+'"]'

                }

                Add-Content -Path $env:GITHUB_OUTPUT -Value "ARTIFACTS_LIST=$artifacts"
                Add-Content -Path $env:GITHUB_ENV -Value "ARTIFACTS_LIST=$artifacts"

                Write-Output "::endgroup::"

                #Upload to LCS
                $assetId = ""
                if($settings.uploadPackageToLCS)
                {
                    Write-Output "::group::Upload artifact to the LCS"
                    OutputInfo "======================================== Upload artifact to the LCS"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Get-D365LcsApiToken -ClientId $settings.lcsClientId -Username "$lcsUsernameSecretname" -Password "$lcsPasswordSecretName" -LcsApiUri "https://lcsapi.lcs.dynamics.com" -Verbose | Set-D365LcsApiConfig -ProjectId $settings.lcsProjectId
                    $assetId = Invoke-D365LcsUpload -FilePath "$deployablePackagePath" -FileType "SoftwareDeployablePackage" -Name "$pname" -Verbose
                    Write-Output "::endgroup::"

                    #Deploy asset to the LCS Environment
                    if($settings.deploy)
                    {
                        Write-Output "::group::Deploy asset to the LCS Environment"
                        OutputInfo "======================================== Deploy asset to the LCS Environment"
                        #Check environment status
                        OutputInfo "======================================== Check $($EnvironmentName) status"

                        $azurePassword = ConvertTo-SecureString $azClientsecretSecretname -AsPlainText -Force
                        $psCred = New-Object System.Management.Automation.PSCredential($settings.azClientId , $azurePassword)

                        OutputInfo "Check az cli installation..."
                        if(-not(Test-Path -Path "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\"))
                        {
                            OutputInfo "az cli installing.."
                            $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'; Remove-Item .\AzureCLI.msi
                            OutputInfo "az cli installed.."
                        }

                        Set-Alias -Name az -Value "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
                        $AzureRMAccount = az login --service-principal -u $settings.azClientId -p "$azClientsecretSecretname" --tenant $settings.azTenantId

                        $PowerState = ""
                        if ($AzureRMAccount) { 
                            #Do Logic
                            OutputInfo "== Logged in == $($settings.azTenantId) "

                            OutputInfo "Getting Azure VM State $($settings.azVmname)"
                            $PowerState = ([string](az vm list -d --query "[?name=='$($settings.azVmname)'].powerState").Trim().Trim("[").Trim("]").Trim('"').Trim("VM ")).Replace(' ','')
                            OutputInfo "....state is $($PowerState)"
                        }
                        
                        OutputInfo "Getting LCS State $($settings.azVmname)"
                        $status = Get-D365LcsEnvironmentMetadata -EnvironmentId $settings.lcsEnvironmentId
                        if($status.DeploymentState -eq "Servicing")
                        {
                            do {
                                Start-Sleep -Seconds 60
                                $status = Get-D365LcsEnvironmentMetadata -EnvironmentId $settings.lcsEnvironmentId
                            
                                OutputInfo "Waiting of previous deployment finish. Current status: $($status.DeploymentState)"
                            }
                            while ($status.DeploymentState -eq "Servicing")
                            
                            OutputInfo "Previous deployment status: $($status.DeploymentState)"
                            Start-Sleep -Seconds 120
                        }
                        if($status.DeploymentState -eq "Failed")
                        {
                            OutputError -message "Previous deployment status is failed. Please ckeck the deployment logs in LCS."
                        }

                        #Startup environment
                        #if($PowerState -ne "running")
                        #{
                            OutputInfo "======================================== Start $($EnvironmentName)"
                            Invoke-D365LcsEnvironmentStart -EnvironmentId $settings.lcsEnvironmentId
                            Start-Sleep -Seconds 60
                        #}

                        #Deploy asset to the LCS Environment
                        OutputInfo "======================================== Deploy asset to the LCS Environment"
                        $WaitForCompletion = $true
                        $PSFObject = Invoke-D365LcsDeployment -AssetId "$($assetId.AssetId)" -EnvironmentId "$($settings.lcsEnvironmentId)" -UpdateName "$pname"
                        $errorCnt = 0
                        $deploymentStatus = ""
                        do {
                            Start-Sleep -Seconds 60
                            $deploymentStatus = Get-D365LcsDeploymentStatus -ActivityId $PSFObject.ActivityId -EnvironmentId $settings.lcsEnvironmentId -FailOnErrorMessage -SleepInSeconds 5

                            if (($deploymentStatus.ErrorMessage))
                            {
                                $errorCnt++
                            }

                            if($errorCnt -eq 3)
                            {
                                if (($deploymentStatus.ErrorMessage) -or ($deploymentStatus.OperationStatus -eq "PreparationFailed")) {
                                    $errorMessagePayload = "`r`n$($deploymentStatus | ConvertTo-Json)"
                                    OutputError -message $errorMessagePayload
                                }
                            }
                            #if deployment is failed throw anyway
                            if(($deploymentStatus.OperationStatus -eq "Failed") -or [string]::IsNullOrEmpty($deploymentStatus.OperationStatus))
                            {
                                $errorMessagePayload = "`r`n$($deploymentStatus | ConvertTo-Json)"
                                OutputError -message $errorMessagePayload
                            }

                            OutputInfo "Deployment status: $($deploymentStatus.OperationStatus)"
                        }
                        while ((($deploymentStatus.OperationStatus -eq "InProgress") -or ($deploymentStatus.OperationStatus -eq "NotStarted") -or ($deploymentStatus.OperationStatus -eq "PreparingEnvironment")) -and $WaitForCompletion)
                        
                        
                        if(($deploymentStatus.OperationStatus -eq "Completed"))
                        {
                            $lcsConfig = Get-D365LcsApiConfig
                            Remove-D365LcsAssetFile -ProjectId $lcsConfig.projectid -AssetId "$($assetId.AssetId)" -BearerToken $lcsConfig.bearertoken -LcsApiUri $lcsConfig.lcsapiuri -Verbose
                            
                        }

                        if($PowerState -ne "running")
                        {
                            OutputInfo "======================================== Stop $($EnvironmentName)"
                            Invoke-D365LcsEnvironmentStop -EnvironmentId $settings.lcsEnvironmentId
                        }
                        Write-Output "::endgroup::"
                    }
                }
            }
            finally
            {
                if (Test-Path -Path $outputDir)
                {
                    Remove-Item -Path $outputDir -Recurse -Force
                }
                if (Test-Path -Path $tempCombinedPackage)
                {
                    Remove-Item -Path $tempCombinedPackage -Force
                }
            }
        }
        else
        {
            throw "No X++ binary package(s) found"
        }
    }
}
catch {
    OutputError -message $_.Exception.Message
}
finally
{
    OutputInfo "Execution is done."
}
