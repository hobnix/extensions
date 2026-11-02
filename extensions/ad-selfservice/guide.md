# Let users change their password

Domain users change their own password on a small web form at `https://<name>/password`, without help from an admin. The form checks the old password against the domain controller with the user's own credentials, so the server holds no admin password for it.

## Before you start
- The domain exists and the capability `ad` is on (see [Users and shares](users-and-shares.md)).
- The gateway proxy is on (`capabilities = ["gateway"]`, see [Give the services local names](gateway.md)).
- The reverse proxy is `traefik-public` (`hs config set reverseProxy traefik-public`) and you have a public name for the form, for example `pw.example.com`.
- Private mode (only the home network) waits for local HTTPS: the form is only served over HTTPS, so today it can only start with a public name.

## Install and switch it on
Not tested on hardware yet.

```bash
sudo hs pkg install ad-selfservice
```

```bash
sudo hs ext enable ad-selfservice
```

## Give the form its public name
In the web interface: open the page Extensions, Password self-service, press **Make public**, check the name (it starts with `pw.` and your first reverse proxy domain when one is set) and type it again in the plan to confirm. Or on the command line. **This opens the form to the internet.** Anyone can try passwords on it. The form limits the tries, but a stranger can block the form for one account for 15 minutes. You type the name to confirm. Not tested on hardware yet.

```bash
sudo hs ext ad-selfservice expose public pw.example.com
```

```bash
sudo hs services apply
```

## Start the form
`start` refuses until the route over HTTPS exists. It starts again by itself after a reboot, until you stop it. Not tested on hardware yet.

```bash
sudo hs ext ad-selfservice start
```

## Use it
Open `https://pw.example.com/password`, enter the user name, the current password and the new password twice. Not tested on hardware yet.

## Look at the tries
Every try is one line: time, address, user name and result. A password is never written down. Not tested on hardware yet.

```bash
sudo hs ext ad-selfservice log
```

## Good to know
- Administrator, krbtgt and Guest are refused with the usual "wrong user name or password" answer. Domain admins change their password with `hs user`.
- The limits are 3 failed tries per account and 5 per address in 15 minutes, 30 tries per minute in all. They are kept in memory and start again from zero after a restart.
- The domain has its own lockout policy. Keep the AD lockout threshold at 0 (never lock) or above 3, or a stranger could lock a real account through the form. `hs ext ad-selfservice status` shows it.
- The form is German or English, like the rest of the server (`hs config set language de`).

## Switch it off
Make the form private so that no public route is left, remove the route, then stop it and switch the package off. Not tested on hardware yet.

```bash
sudo hs ext ad-selfservice expose private
```

```bash
sudo hs services apply
```

```bash
sudo hs ext ad-selfservice stop
```

```bash
sudo hs ext disable ad-selfservice
```

## Check that it worked
- The status shows `Running: yes` and `TLS route: yes`.

```bash
hs ext ad-selfservice status
```

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `start` says "no TLS route to /password" | No public name yet, the route is not made yet, or the reverse proxy is not `traefik-public` | `hs ext ad-selfservice expose public <name>`, then `sudo hs services apply` |
| `start` says the domain controller has no address | The domain controller is stopped | Start it, then run `start` again |
| `start` says smbpasswd was not found | The Samba client tools are missing on the server | Install them, then run `start` again |
| "Use the https address." | The request did not come over HTTPS through the proxy | Open the `https://` address of the form |
| "The password could not be changed right now" | The domain controller does not answer, its address changed, or NTLM is switched off on it | Run `sudo hs ext ad-selfservice start` again to store the new address; check the domain controller |
| "Too many tries" | The limits were reached | Wait 15 minutes |
| The form is gone after `hs ext disable` | The form stops within 10 seconds when the package is off | Switch the package on and run `start` again |

## Next
- [Users and shares](users-and-shares.md)
