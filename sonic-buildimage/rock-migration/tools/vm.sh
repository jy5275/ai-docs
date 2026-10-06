#!/usr/bin/env bash
# Run a command on the local SONiC VS VM (qemu hostfwd 127.0.0.1:2200, admin/YourPaSsWoRd).
# Usage: vm.sh '<cmd>'
sshpass -p 'YourPaSsWoRd' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o LogLevel=ERROR -p 2200 admin@127.0.0.1 "$1"
