# The adapter for a site with no host set up (site.json names no adapter): a publish commits and pushes, and that is
# all. There is no live site to ask, so the confirm answers at once; bin/publish then ends "saved", saying the site has
# no host set up. No files of its own, none a host writes, no limits; nothing to set up or check (offprint adapter
# setup and doctor say so, and succeed).
ADAPTER_PREPARE_FILES=""
adapter_confirm() { return 0; }
adapter_setup() {
  echo "nothing to set up: this site has no host set up (its adapter is none), so a publish commits and pushes, and that is all. To publish to a host, name its adapter in site.json's \"adapter\" (README.md says how)."
}
adapter_doctor() { echo "nothing to check: this site has no host set up (its adapter is none)."; }
