.PHONY: app icon test release clean

app:
	./app/build_app.sh

icon:
	swift scripts/make_icon.swift

test:
	python3 -m unittest discover -s tests -v

release: app
	./scripts/build_release.sh

clean:
	rm -rf app/PrprojDowngrader.app dist
