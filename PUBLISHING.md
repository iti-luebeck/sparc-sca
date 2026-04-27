# Publishing Steps

Run these commands once you have authenticated `gh auth login`.

## Step 1 — Create private forks on GitHub

```bash
gh auth login   # choose GitHub.com → HTTPS → browser or token

# Fork upstreams into aneskovic account (private):
gh repo fork comsec-group/cellift-yosys    --fork-name sparc-sca-yosys    --clone=false
gh repo fork verilator/verilator           --fork-name sparc-sca-verilator --clone=false
gh repo fork comsec-group/cellift-ibex     --fork-name sparc-sca-ibex      --clone=false
gh repo fork proteus-core/proteus          --fork-name sparc-sca-proteus   --clone=false
gh repo fork comsec-group/cellift-chipyard --fork-name sparc-sca-chipyard  --clone=false

# Make forks private:
for repo in sparc-sca-yosys sparc-sca-verilator sparc-sca-ibex sparc-sca-proteus sparc-sca-chipyard; do
  gh repo edit aneskovic/$repo --visibility private
done

# Create the main repo:
gh repo create aneskovic/sparc-sca --private
```

## Step 2 — Push tool forks with local changes

```bash
# Yosys with leakage extension
cd /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys
git remote add aneskovic https://github.com/aneskovic/sparc-sca-yosys.git
git push aneskovic sparc-sca-leakage:main

# Verilator with fstapi fix
cd /mnt/nvme1n1p1/cellift-meta-leakage/tools/verilator
git remote add aneskovic https://github.com/aneskovic/sparc-sca-verilator.git
git push aneskovic sparc-sca-fix:main
```

## Step 3 — Push design forks with evaluation infrastructure

```bash
# Ibex
cd /mnt/nvme1n1p1/cellift-designs/cellift-ibex
git remote add aneskovic https://github.com/aneskovic/sparc-sca-ibex.git
git push aneskovic sparc-sca:main

# Proteus
cd /mnt/nvme1n1p1/cellift-designs/cellift-proteus
git remote add aneskovic https://github.com/aneskovic/sparc-sca-proteus.git
git push aneskovic sparc-sca:main

# Chipyard
cd /mnt/nvme1n1p1/cellift-designs/cellift-chipyard
git remote add aneskovic https://github.com/aneskovic/sparc-sca-chipyard.git
git push aneskovic sparc-sca:main
```

## Step 4 — Push the main sparc-sca repo

```bash
cd /mnt/nvme1n1p1/sparc-sca
git remote add origin https://github.com/aneskovic/sparc-sca.git
git push -u origin main
```

## Step 5 — Verify

```bash
git clone --recurse-submodules https://github.com/aneskovic/sparc-sca.git /tmp/sparc-sca-test
git -C /tmp/sparc-sca-test submodule status
```

## When ready to publish

```bash
# Make all repos public:
for repo in sparc-sca sparc-sca-yosys sparc-sca-verilator sparc-sca-ibex sparc-sca-proteus sparc-sca-chipyard; do
  gh repo edit aneskovic/$repo --visibility public
done

# Then transfer to iti-luebeck org:
# GitHub.com → each repo Settings → General → Transfer ownership → iti-luebeck
# After transfer, update .gitmodules URLs here and push a commit.
```
