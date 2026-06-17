# Test runner for seed-life-dashboard-agent.
#
# This SEED owns six platform-specific ld-* producers (Python wrappers + JS
# scheduled runners with committed tests). The shared ld-shared contract layer
# (post_to_kiosk + the wire/tile protocol + the ld-config template) lives in
# plow-pbc/life-dashboard-skills and is pulled here by ref/sync-ld-shared.sh,
# not vendored — so `test` syncs it first. The recipe runs:
#   - bash -n on the install + verify + sync scripts
#   - the shared post_to_kiosk helper tests (from the synced ld-shared)
#   - this seed's wrapper-contract test (each producer wrapper → right card)
#   - the ld-photo banner-endpoint contract test (network stubbed)
#   - the ld-calendar-nudge + ld-weather + ld-sports JS scheduled tests

test:
    # bash-parse checks first — fail fast on syntax errors.
    bash -n ref/install-bundles.sh
    bash -n ref/verify.sh
    bash -n ref/sync-ld-shared.sh
    # Pull the shared contract layer (override the ref/source via
    # LD_SKILLS_REF / LD_SKILLS_REPO for dev/CI against an unmerged branch).
    bash ref/sync-ld-shared.sh
    # Shared helper tests (both transports) + this seed's wrapper contracts.
    python3 ref/team-skills/ld-shared/scripts/test_post_to_kiosk.py
    python3 ref/team-skills/test_wrappers.py
    python3 ref/team-skills/ld-photo/scripts/test_manage_photo.py
    cd ref/team-skills/ld-calendar-nudge/scheduled && node --test *.test.js
    cd ref/team-skills/ld-weather/scheduled && node --test *.test.js
    cd ref/team-skills/ld-sports/scheduled && node --test *.test.js
