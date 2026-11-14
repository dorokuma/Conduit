.PHONY: check

check:
	@export PATH="$$PATH:/opt/flutter/bin"; \
	if ! command -v flutter >/dev/null 2>&1; then \
		echo "check: flutter SDK not found in PATH or /opt/flutter/bin (run in Flutter dev/CI environment)" >&2; \
		exit 1; \
	fi; \
	flutter analyze && flutter test
