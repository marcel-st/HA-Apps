# SSH Call Home

Creates a reverse SSH tunnel to an external server, enabling remote access to your Home Assistant instance even when it's behind NAT or a firewall.

## Description

This add-on establishes a persistent reverse SSH tunnel from your Home Assistant instance to a remote server. This allows you to access your Home Assistant web interface remotely through the tunnel, even if your local network doesn't have a public IP address or port forwarding capabilities.

## Features

- Automatic reconnection using `autossh`
- Support for multiple architectures (aarch64, amd64, armv7)
- Secure SSH key-based authentication
- Configurable connection parameters
- Keep-alive monitoring to maintain connection stability

## Prerequisites

Before using this add-on, you need:

1. **A remote server** with SSH access (e.g., a VPS or cloud instance)
2. **SSH key pair** - Generate one using the command below
3. **SSH access configured** on the remote server

## Configuration

### Generating SSH Keys

Generate an SSH key pair on your local machine:

```bash
ssh-keygen -t rsa -b 4096 -f callhome_key -N ""
```

This creates two files:
- `callhome_key` - Private key (copy the full content for the add-on configuration)
- `callhome_key.pub` - Public key (add this to `~/.ssh/authorized_keys` on your remote server)

### Add-on Configuration Options

```yaml
ssh_host: "your-server.example.com"
ssh_port: 22
ssh_user: "username"
remote_port: 8123
private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
```

#### Configuration Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ssh_host` | string | Yes | Hostname or IP address of your remote SSH server |
| `ssh_port` | integer | Yes | SSH port on the remote server (typically 22) |
| `ssh_user` | string | Yes | Username for SSH authentication on the remote server |
| `remote_port` | integer | Yes | Port on the remote server where the tunnel will listen (e.g., 8123) |
| `private_key` | password | Yes | Full content of your SSH private key |

### Setting Up the Remote Server

1. **Add the public key** to your remote server:
   ```bash
   cat callhome_key.pub >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

2. **Configure SSH to allow port forwarding** (edit `/etc/ssh/sshd_config`):
   ```
   GatewayPorts yes
   AllowTcpForwarding yes
   ```

3. **Restart SSH service**:
   ```bash
   sudo systemctl restart sshd
   ```

## Installation

1. Add this repository to your Home Assistant add-on store
2. Install the "SSH Call Home" add-on
3. Configure the add-on with your SSH server details
4. Start the add-on

## Usage

Once the add-on is running and the tunnel is established:

- Access your Home Assistant instance via: `http://your-server.example.com:8123`
- Replace `8123` with the `remote_port` you configured

## How It Works

The add-on creates a reverse SSH tunnel using the following command:

```bash
autossh -M 0 -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" \
    -N -R remote_port:homeassistant:8123 user@host -p port
```

This forwards traffic from `remote_port` on your remote server to port 8123 on your Home Assistant instance.

## Troubleshooting

### Connection Won't Establish

- Verify your SSH credentials are correct
- Check that the public key is properly added to the remote server's `authorized_keys`
- Ensure the remote server allows SSH connections and port forwarding
- Check the add-on logs for specific error messages

### Connection Drops Frequently

- Check your internet connection stability
- Verify firewall rules aren't blocking the connection
- Review the `ServerAliveInterval` settings in the `run.sh` script

### Invalid Private Key Error

- Ensure you copied the entire private key, including the header and footer lines
- Verify the key format is correct (OpenSSH format)
- Try regenerating the key pair if the issue persists

## Security Considerations

- Keep your private key secure and never share it
- Use strong authentication on your remote server
- Consider using a dedicated user account with limited privileges
- Regularly update both the add-on and your remote server
- Monitor access logs on your remote server

## Version History

- **1.0.6** - Current version

## Support

For issues or questions, please open an issue on the GitHub repository.
