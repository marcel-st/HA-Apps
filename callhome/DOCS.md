# SSH Call Home Documentation

The `SSH Call Home` add-on creates and maintains a reverse SSH tunnel from Home Assistant to a remote server, so the Home Assistant web interface remains reachable even when the installation is behind NAT or a firewall.

## Features

- Reverse SSH tunnel from the add-on container to a remote host
- Automatic reconnects with `autossh`
- Active health checks every minute
- Automatic rebuild when the SSH session or remote listener becomes stale
- Scheduled maintenance rebuild every 12 hours
- SSH key based authentication

## Configuration

Example configuration:

```yaml
ssh_host: "your-server.example.com"
ssh_port: 22
ssh_user: "username"
remote_port: 8123
private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
```

### Option reference

| Option | Type | Required | Description |
| --- | --- | --- | --- |
| `ssh_host` | string | Yes | Hostname or IP address of the remote SSH server |
| `ssh_port` | integer | Yes | SSH port on the remote server |
| `ssh_user` | string | Yes | SSH username used for authentication |
| `remote_port` | integer | Yes | Port opened on the remote server and forwarded to Home Assistant |
| `private_key` | password | Yes | Full OpenSSH private key used by the add-on |

## Remote server setup

1. Generate an SSH key pair:

   ```bash
   ssh-keygen -t rsa -b 4096 -f callhome_key -N ""
   ```

2. Add the public key to the remote server:

   ```bash
   cat callhome_key.pub >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

3. Ensure the SSH server allows reverse forwarding in `/etc/ssh/sshd_config`:

   ```text
   GatewayPorts yes
   AllowTcpForwarding yes
   ```

4. Restart the SSH daemon on the remote host.

## Connection lifecycle

The add-on:

1. Repairs and validates the configured private key
2. Scans the remote host key
3. Starts an `autossh` reverse tunnel
4. Verifies the control connection is still responsive
5. Verifies that the remote listening port still exists when the remote host supports inspection tools
6. Rebuilds the tunnel on failures
7. Rebuilds the tunnel every 12 hours as preventive maintenance

## Logging and troubleshooting

The add-on log now records:

- tunnel startup and shutdown
- health check failures
- remote listener failures
- automatic rebuild attempts
- scheduled 12-hour rebuilds

If the remote host does not provide `ss`, `netstat`, `lsof`, or `nc`, the add-on logs that condition once and continues with SSH session health checks only.

## Accessing Home Assistant

After the tunnel is healthy, open:

`http://your-server.example.com:remote_port`

Replace `remote_port` with the configured `remote_port` value.

## Security notes

- Use a dedicated SSH user on the remote system
- Limit that user to port-forwarding only when possible
- Protect the private key and rotate it when needed
- Review the remote host SSH logs for repeated reconnects or failures

## Support

For changes in this release, see [CHANGELOG.md](CHANGELOG.md).