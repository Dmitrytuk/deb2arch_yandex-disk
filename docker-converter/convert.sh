#!/usr/bin/env bash
# Конвертация .deb -> .pkg.tar.zst (Arch Linux)
# Использование: convert.sh /work/file.deb
# Переменные окружения:
#   DEPENDS  - зависимости Arch через пробел (напр. "gtk3 nss alsa-lib")
#   PKGNAME  - переопределить имя пакета
#   OUT_DIR  - куда класть результат (по умолчанию - каталог с .deb)
#   MODE     - manual (по умолчанию) | debtap (авто-маппинг зависимостей)
#   AUR_DEPS - AUR-пакеты, которые нужно установить в контейнер перед сборкой/тестом
#   GPG_KEYS - GPG key ID через пробел для импорта (validpgpkeys AUR-пакетов)
#   NO_SCRIPTS=1 - не переносить maintainer-скрипты
#   INSTALL_FILE - свой .install вместо автогенерации из Debian-скриптов
#   TEST_INSTALL=1 - после сборки поставить пакет в контейнер (проверка зависимостей)
set -euo pipefail

DEB="$(readlink -f "${1:?usage: convert.sh file.deb}")"
[[ -f "$DEB" ]] || { echo "Файл не найден: $DEB" >&2; exit 1; }
OUT_DIR="${OUT_DIR:-$(dirname "$DEB")}"
[[ -n "${INSTALL_FILE:-}" ]] && INSTALL_FILE="$(readlink -f "$INSTALL_FILE")"
mkdir -p "$OUT_DIR"

# Подготовка: ключи и AUR-зависимости
if [[ -n "${GPG_KEYS:-}" ]]; then
  gpg --recv-keys $GPG_KEYS
fi
if [[ -n "${AUR_DEPS:-}" ]]; then
  yay -S --noconfirm --needed $AUR_DEPS
fi

# Режим debtap: автоматический перевод зависимостей Debian -> Arch
if [[ "${MODE:-manual}" == "debtap" ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cp "$DEB" "$TMP/" && cd "$TMP"
  debtap -Q "$(basename "$DEB")"
  mv ./*.pkg.tar.* "$OUT_DIR"/
  PKG="$(ls -1t "$OUT_DIR"/*.pkg.tar.* | head -n1)"
  [[ "${TEST_INSTALL:-0}" == 1 ]] && yay -U --noconfirm "$PKG"
  echo "Готово: $PKG"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# 1. Распаковка .deb (ar-архив: control.tar.* + data.tar.*)
mkdir deb ctl
bsdtar -xf "$DEB" -C deb
bsdtar -xf deb/control.tar.* -C ctl
DATA="$(basename deb/data.tar.*)"
cp "deb/$DATA" "$WORK/$DATA"

# 2. Метаданные из control
field() { sed -n "s/^$1: *//p" ctl/control | head -n1; }

name="${PKGNAME:-$(field Package | tr '[:upper:]' '[:lower:]')}"
ver="$(field Version)"
desc="$(field Description | sed "s/'/'\\\\''/g")"
url="$(field Homepage)"
deb_arch="$(field Architecture)"

epoch=""
if [[ $ver == *:* ]]; then epoch="${ver%%:*}"; ver="${ver#*:}"; fi
[[ $ver == *-* ]] && ver="${ver%-*}"          # убрать debian-ревизию
pkgver="${ver//-/_}"; pkgver="${pkgver//\~/_}"

case "$deb_arch" in
  amd64) arch=x86_64 ;;
  arm64) arch=aarch64 ;;
  armhf) arch=armv7h ;;
  i386)  arch=i686 ;;
  all)   arch=any ;;
  *) echo "Неизвестная архитектура: $deb_arch" >&2; exit 1 ;;
esac

# 3. Генерация PKGBUILD
mkdir build && cd build
cp "$WORK/$DATA" .
{
  echo "pkgname='$name'"
  echo "pkgver='$pkgver'"
  echo "pkgrel=1"
  [[ -n $epoch ]] && echo "epoch=$epoch"
  echo "pkgdesc='$desc'"
  echo "arch=('$arch')"
  [[ -n $url ]] && echo "url='$url'"
  echo "license=('custom')"
  echo "depends=(${DEPENDS:-})"
  echo "options=('!strip' '!debug' '!emptydirs')"
  echo "source=('$DATA')"
  echo "noextract=('$DATA')"
  echo "sha256sums=('SKIP')"
  echo "_data='$DATA'"
} > PKGBUILD

# 3b. conffiles -> backup=(), maintainer-скрипты -> .install
if [[ -f "$WORK/ctl/conffiles" ]]; then
  backup="$(sed 's|^/||; s| .*||; /^$/d' "$WORK/ctl/conffiles" | sed "s/.*/'&'/" | tr '\n' ' ')"
  [[ -n $backup ]] && echo "backup=($backup)" >> PKGBUILD
fi

INSTALL_SCRIPTS=""; DEBIAN_ISMS=""
gen_install() {
  local out="$1" s interp
  : > "$out"
  for s in preinst postinst prerm postrm; do
    [[ -f "$WORK/ctl/$s" ]] || continue
    interp="$(sed -n '1s/^#! *//p' "$WORK/ctl/$s")"; interp="${interp:-/bin/sh}"
    {
      echo "_deb_$s() {"
      echo '  local t rc; t="$(mktemp)" || return 1'
      echo "  cat > \"\$t\" <<'DEB2ARCH_EOF'"
      cat "$WORK/ctl/$s"
      echo
      echo "DEB2ARCH_EOF"
      echo "  $interp \"\$t\" \"\$@\"; rc=\$?"
      echo '  rm -f "$t"; return $rc'
      echo "}"
    } >> "$out"
    INSTALL_SCRIPTS+="$s "
  done
  [[ -f "$WORK/ctl/preinst"  ]] && printf 'pre_install() {\n  _deb_preinst install\n}\npre_upgrade() {\n  _deb_preinst upgrade "$2"\n}\n' >> "$out"
  [[ -f "$WORK/ctl/postinst" ]] && printf 'post_install() {\n  _deb_postinst configure\n}\npost_upgrade() {\n  _deb_postinst configure "$2"\n}\n' >> "$out"
  [[ -f "$WORK/ctl/prerm"    ]] && printf 'pre_remove() {\n  _deb_prerm remove\n}\n' >> "$out"
  [[ -f "$WORK/ctl/postrm"   ]] && printf 'post_remove() {\n  _deb_postrm remove\n}\n' >> "$out"
  return 0
}

if [[ -n "${INSTALL_FILE:-}" ]]; then
  [[ -f "$INSTALL_FILE" ]] || { echo "INSTALL_FILE не найден: $INSTALL_FILE" >&2; exit 1; }
  cp "$INSTALL_FILE" "$name.install"
  echo "install='$name.install'" >> PKGBUILD
  INSTALL_SCRIPTS="(свой файл: $(basename "$INSTALL_FILE"))"
elif [[ "${NO_SCRIPTS:-0}" != 1 ]]; then
  gen_install "$name.install"
  if [[ -n $INSTALL_SCRIPTS ]]; then
    echo "install='$name.install'" >> PKGBUILD
    DEBIAN_ISMS="$(cd "$WORK/ctl" && grep -ohE 'apt-key|apt-get|apt-add-repository|sources\.list|update-rc\.d|invoke-rc\.d|deb-systemd-[a-z-]+|dpkg[a-z-]*|debconf|db_(get|set|input|go|stop|purge)|adduser|addgroup|update-alternatives|dh_[a-z_]+|ucf' $INSTALL_SCRIPTS 2>/dev/null | sort -u || true)"
  fi
fi

cat >> PKGBUILD <<'EOF'

_merge() {  # Arch использует merged-/usr: /bin,/sbin,/lib,/lib64 - симлинки
  [[ -d "$pkgdir/$1" && ! -L "$pkgdir/$1" ]] || return 0
  mkdir -p "$pkgdir/$2"
  cp -a "$pkgdir/$1"/. "$pkgdir/$2"/
  rm -rf "$pkgdir/$1"
}

package() {
  bsdtar -xf "$srcdir/$_data" -C "$pkgdir"
  _merge bin usr/bin
  _merge sbin usr/bin
  _merge usr/sbin usr/bin
  _merge lib usr/lib
  _merge lib64 usr/lib
  rm -rf "$pkgdir/etc/apt" "$pkgdir/usr/share/lintian"
}
EOF

# 4. Сборка
PKGDEST="$OUT_DIR" makepkg -f --nodeps --skipinteg --nocheck

echo
echo "Готово:"
ls -1 "$OUT_DIR"/"$name"-*.pkg.tar.* 
if [[ "${TEST_INSTALL:-0}" == 1 ]]; then
  yay -U --noconfirm "$(ls -1t "$OUT_DIR"/"$name"-*.pkg.tar.* | head -n1)"
fi

if [[ -n "$INSTALL_SCRIPTS" ]]; then
  echo
  echo "Maintainer-скрипты встроены в пакет (.INSTALL): $INSTALL_SCRIPTS"
  echo "Проверить содержимое: bsdtar -xOf <пакет>.pkg.tar.zst .INSTALL"
  if [[ -n "$DEBIAN_ISMS" ]]; then
    echo
    echo "ВНИМАНИЕ: скрипты вызывают Debian-специфичные команды (в Arch их нет):"
    echo "$DEBIAN_ISMS" | sed 's/^/  - /'
    echo "Эти места нужно переписать вручную (systemctl, useradd, ln -s и т.п.)."
  fi
fi
