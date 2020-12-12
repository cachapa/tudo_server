#/bin/sh

dart pub get
echo "Compiling binary…"
dart compile exe bin/main.dart -o tudo_server
echo "Installing…"
sudo mv tudo_server /usr/local/bin/
echo "Done."
