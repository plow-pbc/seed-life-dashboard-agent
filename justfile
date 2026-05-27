# Test runner for seed-life-dashboard-agent.
#
# This SEED is unusual among the life-dashboard graph in that it
# vendors source code (the five ld-* bundles) which carries committed
# Python and JS tests. The `test` recipe runs:
#   - bash -n on the install + verify scripts
#   - seed-convention structural verification
#   - the vendored Python helper tests (post_to_kiosk shared module)
#   - the vendored JS scheduled tests for ld-calendar-nudge
#
# The other life-dashboard SEEDs ship no executable code beyond
# shell scripts, so they don't carry a justfile — this is the only
# graph member that does.

test:
    bash -n ref/install-bundles.sh
    bash -n ref/verify.sh
    bash ~/Hacking/seed/ref/verify.sh "$PWD"
    python3 ref/team-skills/ld-shared/scripts/test_post_to_kiosk.py
    cd ref/team-skills/ld-calendar-nudge/scheduled && node --test *.test.js
