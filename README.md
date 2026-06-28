# Tether — install

Public distribution for the Tether CLI: the install scripts and released binaries.
The source code lives in the private `tetherlab/tether` repo.

## Install

macOS and Linux:

    curl -fsSL https://get.tether.sh | sh

Until `get.tether.sh` is live, use the raw URL:

    curl -fsSL https://raw.githubusercontent.com/tetherlab/install/main/install.sh | sh

Windows (PowerShell):

    irm https://raw.githubusercontent.com/tetherlab/install/main/install.ps1 | iex

The installer resolves the latest release, verifies the download against `SHA256SUMS`,
installs `tether` to `~/.tether/bin`, and starts onboarding.
