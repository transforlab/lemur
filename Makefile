all:
	elm make --yes src/Main.elm --output=public/elm.js

deps:
	elm package install --yes
	git submodule init
	git submodule update
	npm install

loc:
	find src -regex ".*elm" | xargs wc -l
	find elm-diagrams/Diagrams -regex ".*elm" | xargs wc -l

