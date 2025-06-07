# Give user access to docker socket
custom-access-docker:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo systemctl --global enable --now docker.service
    sudo usermod -aG docker $USER

# Install only Flatpaks
custom-install-flatpaks:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Installing Flatpaks..."
    xargs -a <(curl --retry 3 -sL https://raw.githubusercontent.com/edifus/bazzite/main/custom_files/flatpaks/flatpaks) flatpak --system -y install
    echo "Flatpaks installation complete."

# Install Nix daemon
custom-install-nix:
    #!/usr/bin/bash

    set -eoux pipefail

    NIX_DAEMON_SCRIPT="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
    NIX_INSTALLER="https://install.determinate.systems/nix"

    echo "=== Setting up Nix package manager ==="
    curl --proto '=https' --tlsv1.2 -sSf -L "$NIX_INSTALLER" | sh -s -- install --no-confirm
    [ -f "$NIX_DAEMON_SCRIPT" ] && . "$NIX_DAEMON_SCRIPT"

    echo 'download-buffer-size = 536870912' | tee --append /etc/nix/nix.conf

    cat >> /etc/nix/nix.conf << EOF
    # Sane defaults
    download-buffer-size = 536870912
    experimental-features = nix-command flakes auto-allocate-uids cgroups fetch-closure recursive-nix configurable-impure-env ca-derivations impure-derivations
    substituters = https://cache.nixos.org/
    trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE=
    trusted-substituters = https://cache.garnix.io https://cache.nixos.org https://nix-community.cachix.org https://numtide.cachix.org
    trusted-users = root @wheel
    EOF

# Restart Bluetooth to fix issues
custom-fix-bt:
    #!/usr/bin/env bash
    set -euo pipefail
    trap '[[ $BASH_COMMAND != echo* ]] && echo "+ $BASH_COMMAND"' DEBUG

    echo "Fixing Bluetooth..."
    sudo rfkill unblock all
    sudo rmmod btusb
    sudo modprobe btusb
    echo "Bluetooth fix complete."

# Manage SSD encryption optimizations (Workqueue and TRIM)
custom-ssd-crypto:
    #!/usr/bin/env bash
    set -euo pipefail

    # Get LUKS2 devices
    luks_devices=$(sudo dmsetup ls --target crypt) || {
        echo "No LUKS devices found."
        exit 1
    }

    # Display devices and their settings
    echo "LUKS2 Devices and Settings:"
    echo "=========================="

    while read -r name _; do
        [ -z "$name" ] && continue

        status=$(sudo cryptsetup status "$name")
        device=$(echo "$status" | grep "device:" | cut -d: -f2 | xargs)

        # Skip if not LUKS2
        sudo cryptsetup isLuks --type luks2 "$device" 2>/dev/null || continue

        flags=$(echo "$status" | grep "flags:" | cut -d: -f2 | xargs)
        echo "Device: $name (${device})"
        echo "- TRIM: $(echo "$flags" | grep -q "discards" && echo "enabled" || echo "disabled")"
        echo "- No read workqueue: $(echo "$flags" | grep -q "no_read_workqueue" && echo "enabled" || echo "disabled")"
        echo "- No write workqueue: $(echo "$flags" | grep -q "no_write_workqueue" && echo "enabled" || echo "disabled")"
        echo "--------------------------"
    done <<<"$luks_devices"

    # Get and validate device selection
    read -p "Enter LUKS device name to optimize (or press Enter to exit): " device
    [ -z "$device" ] && exit 0

    if ! sudo cryptsetup status "$device" &>/dev/null; then
        echo "Error: Device $device not found"
        exit 1
    fi

    source_dev=$(sudo cryptsetup status "$device" | grep "device:" | cut -d: -f2 | xargs)
    if ! sudo cryptsetup isLuks --type luks2 "$source_dev" 2>/dev/null; then
        echo "Error: Device $device is not a LUKS2 device"
        exit 1
    fi

    # Check TRIM support
    supports_trim=$(sudo lsblk --pairs --discard "$source_dev" | head -n1 | grep -E 'DISC-GRAN="[1-9].*DISC-MAX="[1-9]')

    # Show menu options
    echo -e "\nSelect optimization option:"
    if [[ -n "$supports_trim" ]]; then
        options=(
            "Enable workqueue optimizations with TRIM"
            "Enable workqueue optimizations without TRIM"
            "Disable all optimizations"
        )
    else
        options=(
            "Enable workqueue optimizations"
            "Disable all optimizations"
        )
    fi

    for i in "${!options[@]}"; do
        echo "$((i + 1))) ${options[i]}"
    done

    read -p "Select option (1-${#options[@]}): " choice
    [[ ! "$choice" =~ ^[1-${#options[@]}]$ ]] && {
        echo "Invalid option"
        exit 1
    }

    # Apply selected optimization
    case $choice in
        1)
            if [[ -n "$supports_trim" ]]; then
                sudo cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards --persistent refresh "$device"
                echo "✓ Workqueue optimizations enabled with TRIM"
            else
                sudo cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --persistent refresh "$device"
                echo "✓ Workqueue optimizations enabled"
            fi
            ;;
        2)
            if [[ -n "$supports_trim" ]]; then
                sudo cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue --persistent refresh "$device"
                echo "✓ Workqueue optimizations enabled without TRIM"
            else
                sudo cryptsetup --persistent refresh "$device"
                echo "✓ All optimizations disabled"
            fi
            ;;
        3)
            sudo cryptsetup --persistent refresh "$device"
            echo "✓ All optimizations disabled"
            ;;
    esac

# Clean up old packages and Docker/Podman images and volumes
custom-clean:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Cleaning up system..."
    docker system prune -af
    podman system prune -af
    flatpak uninstall --unused
    rpm-ostree cleanup -bm
    nix-collect-garbage -d
    sudo docker system prune -af
    sudo podman system prune -af
    sudo -i nix-collect-garbage -d
