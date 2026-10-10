# Dot-sourced by deploy.ps1 / destroy.ps1 from the project root (gadgethub/).
# Loads .env and exposes its values to the AWS CLI, Docker and Terraform.

$EnvFile = ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Host ".env not found - copy .env.example to .env and fill in the values." -ForegroundColor Red
    exit 1
}

function Read-EnvValue {
    param([string]$Name, [string]$File = $EnvFile)
    $line = Get-Content $File | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1].Trim()
}

# --- AWS credentials + region ----------------------------------------------
# Exported as the standard AWS_* variables, which the AWS CLI and Terraform's
# AWS provider both read. Left unset when empty so an "aws configure" profile
# still works as a fallback.
foreach ($name in "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY") {
    $value = Read-EnvValue -Name $name
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        Set-Item -Path "Env:$name" -Value $value
    }
}
$awsRegion = Read-EnvValue -Name "AWS_REGION"
if (-not [string]::IsNullOrWhiteSpace($awsRegion)) {
    $env:AWS_REGION = $awsRegion
    $env:AWS_DEFAULT_REGION = $awsRegion
}

# --- Terraform variables -----------------------------------------------------
# Terraform auto-reads any TF_VAR_<name> environment variable as the value for
# variable <name>. Anything left empty in .env falls back to the default in
# terraform/variables.tf.
$tfVars = [ordered]@{
    USE_CUSTOM_DOMAIN = "use_custom_domain"
    DOMAIN_NAME       = "domain_name"
    APP_SUBDOMAIN     = "app_subdomain"
    OPENAI_MODEL      = "openai_model"
    CONTAINER_CPU     = "container_cpu"
    CONTAINER_MEMORY  = "container_memory"
    DESIRED_COUNT     = "desired_count"
}
foreach ($name in $tfVars.Keys) {
    $value = Read-EnvValue -Name $name
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        Set-Item -Path "Env:TF_VAR_$($tfVars[$name])" -Value $value
    }
}

# --- Pre-flight: credentials must work and target the expected account -------
$actualAccountId = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "AWS credentials were rejected - check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in .env." -ForegroundColor Red
    exit 1
}
$expectedAccountId = Read-EnvValue -Name "AWS_ACCOUNT_ID"
if (-not [string]::IsNullOrWhiteSpace($expectedAccountId) -and $actualAccountId -ne $expectedAccountId) {
    Write-Host ""
    Write-Host "AWS account mismatch: credentials belong to $actualAccountId but .env sets AWS_ACCOUNT_ID=$expectedAccountId." -ForegroundColor Red
    exit 1
}
