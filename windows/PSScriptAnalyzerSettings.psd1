@{
    ExcludeRules = @(
        # UTF-8 without BOM is correct for cross-platform PowerShell 7+ scripts.
        # Adding a BOM would break Unix tooling (git, shellcheck, bash) that reads the file header.
        # PS 5.1 on Windows can read UTF-8-no-BOM files without issue.
        'PSUseBOMForUnicodeEncodedFile',

        # All three scripts (runner-loop.ps1, install.ps1, uninstall.ps1) are console tools whose
        # output is intended for the terminal. Write-Host is intentional and correct here — it
        # writes to the Information stream which the scheduled-task log captures. Suppressed
        # globally so each Write-Host call does not require a per-line attribute.
        'PSAvoidUsingWriteHost'
    )
}
