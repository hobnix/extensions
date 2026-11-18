# Try the extension command protocol

A demo package for people who write extensions. It shows the command protocol version 1: the core starts `demo.py`, sends one request line, and prints what the answer's `data` says.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs ext enable protocol-demo
```

## Say hello
```bash
hs ext protocol-demo hello Anna
```

The extension answers with `text`, which a command run by a person prints. Add `HS_LANG=de` to get the German greeting.

## See the machine-readable form
```bash
hs sys ext protocol-demo list
```

Each row of `data` is one line, cells are separated by a tab, an empty cell is `-`.

## See the timeout
```bash
hs sys ext protocol-demo slow; echo $?
```

The row has the flag `timeout:2`. The core stops the extension and everything it started and exits with 124.
