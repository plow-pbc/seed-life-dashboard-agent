# Test runner for seed-life-dashboard-agent.
#
# This SEED is unusual among the life-dashboard graph in that it owns
# source code (the five ld-* bundles) which carries committed Python
# and JS tests. The `test` recipe runs:
#   - bash -n on the install + verify scripts
#   - seed-convention structural verification
#   - the ld-shared Python helper tests (post_to_kiosk shared module)
#   - the ld-calendar-nudge JS scheduled tests
#
# The other life-dashboard SEEDs ship no executable code beyond
# shell scripts, so they don't carry a justfile — this is the only
# graph member that does.

test:
    # bash-parse checks first — fail fast on syntax errors.
    bash -n ref/install-bundles.sh
    bash -n ref/verify.sh
    # Bundle tests — the actual value this justfile provides over the
    # other SEEDs in the graph (which carry no executable source).
    # Seed-convention structural verification is a separate
    # repo-external concern (run via the bot's seed-conformance gate);
    # `just test` deliberately doesn't reference operator-specific
    # paths like `~/Hacking/seed/...` so it runs cleanly in any CI.
    python3 ref/team-skills/ld-shared/scripts/test_post_to_kiosk.py
    cd ref/team-skills/ld-calendar-nudge/scheduled && node --test *.test.js
