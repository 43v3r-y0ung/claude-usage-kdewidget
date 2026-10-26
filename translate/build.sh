#!/bin/sh
# Extracts the strings into template.pot, merges them into every <lang>.po
# and compiles those into package/contents/locale. Needs gettext.
#   translate/build.sh          update and compile
#   translate/build.sh --check  also list untranslated and fuzzy strings
set -e
cd "$(dirname "$0")"
id=$(sed -n 's/.*"Id": *"\([^"]*\)".*/\1/p' ../package/metadata.json)
domain="plasma_applet_$id"

find ../package -name '*.qml' -o -name '*.js' | sort | xgettext \
    --from-code=UTF-8 -L JavaScript --kde \
    -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
    --package-name="$id" --msgid-bugs-address="https://github.com/43v3r-y0ung/claude-usage-kdewidget/issues" \
    --files-from=- -o template.pot
sed -i 's/charset=CHARSET/charset=UTF-8/' template.pot

for po in *.po; do
    [ -e "$po" ] || continue
    lang=${po%.po}
    msgmerge --quiet --update --backup=none "$po" template.pot
    mkdir -p "../package/contents/locale/$lang/LC_MESSAGES"
    msgfmt --check -o "../package/contents/locale/$lang/LC_MESSAGES/$domain.mo" "$po"
    echo "$lang: $(msgfmt --statistics -o /dev/null "$po" 2>&1)"
    [ "$1" = "--check" ] && msgattrib --only-fuzzy "$po" && msgattrib --untranslated "$po"
done
true
