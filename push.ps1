$ErrorActionPreference = 'Stop'
# Run after: gh auth login
git init
git add .
git commit -m "sky130 macro CI: synth -> PnR 0-DRC -> GDS -> DRC -> LVS"
gh repo create sky130-macro-ci --private --source=. --remote=origin --push
gh run watch
