.PHONY: app icon test test-bundled release clean

app:
	./app/build_app.sh

icon:
	swift scripts/make_icon.swift

test:
	python3 -m unittest discover -s tests -v

# Run the engine tests with the Python runtime that ships inside the app.
test-bundled:
	./scripts/fetch_python.sh
	PRPROJ_PYTHON=build/python-universal/bin/python3 python3 -m unittest discover -s tests -v

release: app
	./scripts/build_release.sh

clean:
	rm -rf app/PrprojDowngrader.app dist build/swift
