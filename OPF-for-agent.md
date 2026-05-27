# Using the Privacy Filter Service from Another Host

This guide explains how to configure git on your local machine to use the privacy-filter-service running on a remote host. You do not need to install the service or the OPF model locally. The hooks will send file contents and commit messages to the remote service over HTTP.

---

## What You Need

- The remote host IP or hostname where the service is running
- Network access to that host on port `8765`
- Bash, git, curl, and python3 installed locally

The service is currently running on `M2S2VMUbuntuA6000` (internal network) with an NVIDIA RTX A6000 GPU and CUDA 12.6. Ask your network admin for the reachable IP if you do not have it.

---

## Quick Setup

### 1. Copy the Hooks to Your Machine

The hooks live in the service repository. You only need three files:

```bash
# On the remote host (or from the repo)
scp user@M2S2VMUbuntuA6000:/home/shili-dev/project/privacy-filter-service/hooks/_lib.sh ~/.config/git/hooks/
scp user@M2S2VMUbuntuA6000:/home/shili-dev/project/privacy-filter-service/hooks/pre-commit ~/.config/git/hooks/
scp user@M2S2VMUbuntuA6000:/home/shili-dev/project/privacy-filter-service/hooks/commit-msg ~/.config/git/hooks/

# Make them executable
chmod +x ~/.config/git/hooks/_lib.sh ~/.config/git/hooks/pre-commit ~/.config/git/hooks/commit-msg
```

If you prefer, clone the repository and copy the files from `hooks/`.

### 2. Point Git Hooks at the Remote Service

Tell git to use your hooks directory:

```bash
git config --global core.hooksPath ~/.config/git/hooks
```

Tell the hooks where the remote service lives. Replace `REMOTE_IP` with the actual IP or hostname.

```bash
export PRIVACY_FILTER_URL="http://REMOTE_IP:8765"
```

To make this permanent, add it to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
echo 'export PRIVACY_FILTER_URL="http://REMOTE_IP:8765"' >> ~/.bashrc
```

### 3. Verify Connectivity

```bash
curl -fsS "${PRIVACY_FILTER_URL}/health"
```

You should see something like:

```json
{"ready": true, "device": "cuda", "uptime_s": 1234, "version": "0.1.0"}
```

If this fails, check your network path and firewall rules.

### 4. Test the Hook

Create a test repo and try a commit with fake PII:

```bash
cd /tmp
mkdir pf-test && cd pf-test
git init
git config core.hooksPath ~/.config/git/hooks   # if not global
echo "Contact <PRIVATE_EMAIL> or call <PRIVATE_PHONE>" > readme.txt
git add readme.txt
git commit -m "add contact info"
```

The pre-commit hook should block the commit and print a message like:

```
[privacy-filter] blocked commit: detected PII in 1 staged file(s), 2 span(s)
[privacy-filter] by label: private_email=1 private_phone=1
[privacy-filter] review patch: /tmp/pf-test/.git/privacy-filter/redact-...
[privacy-filter] apply with: git apply --index "..."
```

A `.patch` file is generated in `.git/privacy-filter/`. Review it, then apply the redactions:

```bash
git apply --index .git/privacy-filter/redact-*.patch
git commit -m "add contact info"
```

The commit-msg hook will also redact PII in your commit message. Try:

```bash
git commit -m "Fix bug reported by <PRIVATE_EMAIL>"
```

After the commit, check the log. The message will show `<PRIVATE_EMAIL>` instead of the real address.

---

## Environment Variables

These variables control hook behavior. Set them in your shell or in `~/.bashrc`.

| Variable | Default | What It Does |
|----------|---------|--------------|
| `PRIVACY_FILTER_URL` | `http://127.0.0.1:8765` | URL of the remote service. **This is the only variable you must change.** |
| `PRIVACY_FILTER_TIMEOUT_S` | `5` | HTTP timeout in seconds (1 to 60). Increase if the remote host is slow or far away. |
| `PRIVACY_FILTER_MAX_FILE_BYTES` | `262144` | Maximum file size the hook will scan, in bytes. The service itself rejects anything over 1 MB. |
| `PRIVACY_FILTER_SKIP` | `0` | Set to `1` to skip all privacy-filter checks for a single commit. |
| `PRIVACY_FILTER_MAX_INFLIGHT_WARNS` | `1` | Maximum "fail-open" warnings printed per 5-minute window. Prevents log spam when the service is unreachable. |

### Example: Slow Network

If the remote host is on another continent or VPN, raise the timeout:

```bash
export PRIVACY_FILTER_URL="http://10.0.0.5:8765"
export PRIVACY_FILTER_TIMEOUT_S=15
```

### Example: Large Files

If you routinely stage files up to 512 KB:

```bash
export PRIVACY_FILTER_MAX_FILE_BYTES=524288
```

---

## Handling False Positives

The model is conservative. It sometimes flags text that is not actually sensitive. Here is how to deal with that.

### What the Hook Does on Detection

When the pre-commit hook finds PII, it:

1. Blocks the commit (exit 1)
2. Writes a unified diff patch to `.git/privacy-filter/redact-<timestamp>-<pid>.patch`
3. Prints the patch path and an apply command

The patch shows exactly what would change. Review it before applying.

### Option 1: Apply the Patch (Accept the Redaction)

If the flagged text really is PII:

```bash
git apply --index .git/privacy-filter/redact-*.patch
git commit -m "your message"
```

This replaces the sensitive text with placeholders like `<PRIVATE_EMAIL>` in your staged files.

### Option 2: Skip the Check (Reject the Redaction)

If the model flagged something harmless, you can skip the check for that commit:

```bash
PRIVACY_FILTER_SKIP=1 git commit -m "your message"
```

This bypasses both pre-commit and commit-msg hooks for this commit only. The environment variable is scoped to the single command, so subsequent commits run normally.

You can also use git's built-in bypass:

```bash
git commit --no-verify -m "your message"
```

The difference between the two:

| Mechanism | Scope | What it skips |
|-----------|-------|---------------|
| `PRIVACY_FILTER_SKIP=1` | Single commit | Only privacy-filter hooks (pre-commit and commit-msg). Other hooks still run. |
| `git commit --no-verify` | Single commit | **All** hooks (pre-commit, commit-msg, and any others installed by tools like Husky or pre-commit). |

Use `PRIVACY_FILTER_SKIP=1` when you want to bypass the privacy filter but still run other checks (linting, tests, etc.). Use `--no-verify` only when you need to skip every hook. Both are safe. The hooks are designed to fail open, so skipping them does not break anything.

### Option 3: Edit the File and Retry

Sometimes a small rewording avoids the false positive. For example, instead of:

```
<PRIVATE_PERSON> was born <PRIVATE_DATE>
```

Try:

```
A. Smith was born in the early 90s
```

Then stage and commit normally.

### Common False Positive Patterns

| Pattern | Why It Flags | Workaround |
|---------|--------------|------------|
| Test data with fake emails like `<PRIVATE_EMAIL>` | `private_email` | Skip the check, or use obviously fake strings like `test AT example DOT com` |
| Public URLs in documentation | `private_url` | Skip the check, or redact and restore later |
| Dates in changelogs | `private_date` | Skip the check, or rephrase ("January 2020" instead of "2020-01-15") |
| Placeholder names like "<PRIVATE_PERSON>" | `private_person` | Skip the check, or use generic terms ("the user", "a customer") |
| API keys in `.env.example` files | `secret` | Skip the check, or move examples to documentation |

---

## Verification Checklist

Run through these steps to confirm everything works.

### 1. Service Reachable

```bash
curl -fsS "${PRIVACY_FILTER_URL}/health" | python3 -m json.tool
```

Expected: `ready: true`

### 2. Model Info

```bash
curl -fsS "${PRIVACY_FILTER_URL}/model-info" | python3 -m json.tool
```

Expected: JSON with `device`, `labels`, `output_mode`, `decode_mode`

### 3. Direct Redaction Test

```bash
curl -fsS -X POST "${PRIVACY_FILTER_URL}/redact/text" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Email <PRIVATE_EMAIL> or call 555-123-4567"}'
```

Expected: `Email <PRIVATE_EMAIL> or call <PRIVATE_PHONE>`

### 4. Pre-commit Hook Blocks PII

```bash
cd /tmp
rm -rf pf-verify && mkdir pf-verify && cd pf-verify
git init
git config core.hooksPath ~/.config/git/hooks
echo "Contact <PRIVATE_EMAIL>" > contact.txt
git add contact.txt
git commit -m "add contact"
```

Expected: commit blocked, patch generated.

### 5. Commit-msg Hook Redacts Message

```bash
git apply --index .git/privacy-filter/redact-*.patch
git commit -m "Fix bug reported by <PRIVATE_EMAIL>"
git log -1 --format=%B
```

Expected: message contains `<PRIVATE_EMAIL>`

### 6. Skip Mechanism Works

```bash
echo "Another test bob@example.com" > test.txt
git add test.txt
PRIVACY_FILTER_SKIP=1 git commit -m "skip test with <PRIVATE_EMAIL>"
```

Expected: commit succeeds, no patch generated.

### 7. Fail-open Works

Temporarily break the URL and try to commit:

```bash
PRIVACY_FILTER_URL="http://invalid:8765" git commit -m "fail open test"
```

Expected: warning printed, commit succeeds.

---

## Troubleshooting

### "service down, fail-open" Warning

The hook cannot reach the remote service. Check:

- Is `PRIVACY_FILTER_URL` set correctly?
- Can you `ping` or `curl` the remote host?
- Is a firewall blocking port 8765?
- Is the service running on the remote host? (`systemctl --user status privacy-filter`)

### "Partial staging not supported"

The file has both staged and unstaged changes. Fully stage or fully unstage it:

```bash
git add <file>        # fully stage
git restore --staged <file>   # fully unstage
```

### Patch Apply Fails

Rarely, the generated patch does not apply cleanly. This can happen with unusual line endings or binary-looking text. In that case:

1. Review the patch manually: `cat .git/privacy-filter/redact-*.patch`
2. Apply changes by hand, or
3. Skip the check: `PRIVACY_FILTER_SKIP=1 git commit`

### Timeout Errors

If you see `redaction request failed` or `curl` timeouts:

```bash
export PRIVACY_FILTER_TIMEOUT_S=15
```

Large files or slow networks need more time.

---

## Security Notes

- **Data leaves your machine**. The hook sends staged file contents and commit messages to the remote service over plain HTTP. Use this only on trusted internal networks.
- **No encryption by default**. If you need HTTPS, set `PRIVACY_FILTER_URL` to an `https://` endpoint and ensure the remote service is behind a reverse proxy with TLS.
- **Model path is never exposed**. The `/model-info` endpoint does not leak filesystem paths.
- **Logs are sanitized**. The remote service does not log raw text content.

### HTTPS / TLS Best Practices

If you run the service across untrusted networks, use TLS end-to-end.

1. **Reverse proxy** — Put the service behind nginx, Caddy, or another reverse proxy that terminates TLS. Forward to `http://127.0.0.1:8765` on the service host.
2. **Certificate** — Use a valid certificate from your internal CA or a public CA. Avoid self-signed certs unless every client trusts the CA.
3. **Client configuration** — Point hooks at the HTTPS endpoint:

   ```bash
   export PRIVACY_FILTER_URL="https://privacy-filter.internal.example.com"
   ```

4. **Certificate pinning (optional)** — If you use a private CA, distribute the CA certificate to clients and configure `curl` to trust it:

   ```bash
   export CURL_CA_BUNDLE=/path/to/internal-ca.crt
   ```

5. **Do not expose the service to the public internet** without authentication. The API has no built-in auth. If you must expose it, add an API gateway or VPN in front.

---

## Summary

1. Copy the three hook files to `~/.config/git/hooks/`
2. Set `git config --global core.hooksPath ~/.config/git/hooks`
3. Set `PRIVACY_FILTER_URL` to the remote service address
4. Verify with `curl ${PRIVACY_FILTER_URL}/health`
5. Commit as normal. If PII is detected, review the patch and apply it, or skip with `PRIVACY_FILTER_SKIP=1`

That is it. No local model, no GPU, no systemd unit. Just git hooks talking to a remote service.
