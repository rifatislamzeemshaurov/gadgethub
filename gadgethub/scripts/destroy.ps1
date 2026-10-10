param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$ProjectName = ""       # defaults to PROJECT_NAME in .env
)
$ErrorActionPreference = "Stop"

# PowerShell 5.1 note: $ErrorActionPreference = "Stop" only affects cmdlet
# errors, NOT native-executable failures (terraform, aws). Check $LASTEXITCODE
# explicitly after each so a failure here can't silently continue.
function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FAILED: $Step (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

# Validate environment parameter
if ($Environment -notmatch '^(dev|test|prod)$') {
    Write-Host "Error: Invalid environment '$Environment'" -ForegroundColor Red
    Write-Host "Available environments: dev, test, prod" -ForegroundColor Yellow
    exit 1
}

# Move to project root (gadgethub/), then into terraform/
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# --- Load .env: AWS credentials/region, custom domain, compute sizing -------
. "$PSScriptRoot\load-env.ps1"
if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = Read-EnvValue -Name "PROJECT_NAME" }
if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = "gadgethub" }

Write-Host "Preparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Yellow

# --- Load OPENAI_API_KEY from .env ----------------------------------------
# terraform destroy still needs every variable resolved (it re-evaluates the
# config graph), so the key has to be supplied the same way as on deploy.
$envFile = ".env"
if (-not (Test-Path $envFile)) {
    Write-Host ".env not found - cannot read OPENAI_API_KEY." -ForegroundColor Red
    exit 1
}
$openaiLine = Get-Content $envFile | Where-Object { $_ -match '^OPENAI_API_KEY=' } | Select-Object -First 1
if ($openaiLine) {
    $env:TF_VAR_openai_api_key = ($openaiLine -split '=', 2)[1].Trim()
}

# terraform destroy still re-evaluates the whole config graph, so every
# required variable (no default) has to resolve even though destroy doesn't
# use these values for anything - placeholders are fine here.
function Read-EnvValueOrPlaceholder {
    param([string]$Name, [string]$File, [string]$Placeholder)
    $line = Get-Content $File | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) { return $Placeholder }
    $value = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $Placeholder }
    return $value
}
$env:TF_VAR_qdrant_url = Read-EnvValueOrPlaceholder -Name "QDRANT_URL" -File $envFile -Placeholder "https://placeholder"
$env:TF_VAR_qdrant_api_key = Read-EnvValueOrPlaceholder -Name "QDRANT_API_KEY" -File $envFile -Placeholder "placeholder"
$env:TF_VAR_api_key = Read-EnvValueOrPlaceholder -Name "API_KEY_UI" -File $envFile -Placeholder "placeholder"

Set-Location terraform

# Check if workspace exists
$workspaces = terraform workspace list
if (-not ($workspaces | Select-String "\b$Environment\b")) {
    Write-Host "Error: Workspace '$Environment' does not exist" -ForegroundColor Red
    Write-Host "Available workspaces:" -ForegroundColor Yellow
    terraform workspace list
    exit 1
}

# Select the workspace
terraform workspace select $Environment
Assert-LastExitCode "terraform workspace select $Environment"

Write-Host "Emptying S3 buckets..." -ForegroundColor Yellow

# Get AWS Account ID for bucket names
$awsAccountId = aws sts get-caller-identity --query Account --output text

# Define bucket names with account ID (matches main.tf's naming)
$FrontendBucket = "$ProjectName-$Environment-frontend-$awsAccountId"
$MemoryBucket = "$ProjectName-$Environment-memory-$awsAccountId"

# Empty frontend bucket if it exists
$frontendExists = aws s3 ls "s3://$FrontendBucket" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Emptying $FrontendBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$FrontendBucket" --recursive
} else {
    Write-Host "  Frontend bucket not found or already empty" -ForegroundColor Gray
}

# Empty memory bucket if it exists
$memoryExists = aws s3 ls "s3://$MemoryBucket" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Emptying $MemoryBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$MemoryBucket" --recursive
} else {
    Write-Host "  Memory bucket not found or already empty" -ForegroundColor Gray
}

# `image_tag` isn't used by anything `destroy` needs to actually remove
# (the ECR repo has force_delete = true, so leftover images don't block it),
# but the variable is required by the config, so pass a placeholder.
Write-Host "Running terraform destroy..." -ForegroundColor Yellow

terraform destroy -var="project_name=$ProjectName" -var="environment=$Environment" -var="image_tag=destroy" -auto-approve
Assert-LastExitCode "terraform destroy"

Write-Host "Infrastructure for $Environment has been destroyed!" -ForegroundColor Green
Write-Host ""
Write-Host "To remove the workspace completely, run:" -ForegroundColor Cyan
Write-Host "   terraform workspace select default" -ForegroundColor White
Write-Host "   terraform workspace delete $Environment" -ForegroundColor White
