#!/bin/bash
# Install Terraform on Amazon Linux 2023 / Ubuntu / macOS

set -e

OS=$(uname -s)
ARCH=$(uname -m)
TF_VERSION="1.9.5"

install_macos() {
    if ! command -v brew &>/dev/null; then
        echo "Homebrew not found. Install from https://brew.sh"
        exit 1
    fi
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
}

install_linux_amd64() {
    wget -q "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
    unzip -q "terraform_${TF_VERSION}_linux_amd64.zip"
    sudo mv terraform /usr/local/bin/
    rm "terraform_${TF_VERSION}_linux_amd64.zip"
}

install_linux_arm64() {
    wget -q "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_arm64.zip"
    unzip -q "terraform_${TF_VERSION}_linux_arm64.zip"
    sudo mv terraform /usr/local/bin/
    rm "terraform_${TF_VERSION}_linux_arm64.zip"
}

echo "Detected OS: $OS, Arch: $ARCH"

case $OS in
    Darwin)  install_macos ;;
    Linux)
        case $ARCH in
            x86_64)  install_linux_amd64 ;;
            aarch64) install_linux_arm64 ;;
            *) echo "Unsupported arch: $ARCH" && exit 1 ;;
        esac
        ;;
    *) echo "Unsupported OS: $OS" && exit 1 ;;
esac

echo ""
echo "Terraform installed:"
terraform version

echo ""
echo "Configure AWS credentials before running terraform:"
echo "  aws configure"
echo "  OR: export AWS_PROFILE=your-profile"
echo "  OR: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..."
