# :rocket: Action 'RunPipeline' 
Run pipeline in FSC-PS repository 
## :wrench: Parameters 
## :arrow_down: Inputs 
### version (Default: '') 
 The Dynamics Application Version 

### type (Default: 'FSCM') 
 The application type. FSCM or Commerce 

### settingsJson (Default: '') 
 Settings from repository in compressed Json format 

### environment_name (Default: '') 
 The Dynamics Environment Name 

### secretsJson (Default: '{"insiderSasToken":"","licenseFileUrl":"","CodeSignCertificateUrl":"","CodeSignCertificatePw":""}') 
 Secrets from repository in compressed Json format 

### token (Default: '${{ github.token }}') 
 The GitHub token running the action 

### actor (Default: '${{ github.actor }}') 
 The GitHub actor running the action 

## :arrow_up: Outputs 
### package_name (Default: '') 
 Package name 

### modelfile_path (Default: '') 
 Modelfile path 

### artifacts_path (Default: '') 
 Artifacts folder path 

### artifacts_list (Default: '') 
 Artifacts folder path 

### package_path (Default: '') 
 Package path 


