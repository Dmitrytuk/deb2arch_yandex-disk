FROM archlinux:latest

# 0. Устойчивость к медленным зеркалам: свой mirrorlist, без параллельных загрузок.
#    Свой список зеркал: docker build --build-arg MIRRORS="https://host1/archlinux https://host2/archlinux" .
ARG MIRRORS="https://geo.mirror.pkgbuild.com https://mirror.leaseweb.net/archlinux https://mirrors.kernel.org/archlinux https://mirror.rackspace.com/archlinux"
RUN : > /etc/pacman.d/mirrorlist \
 && for m in $MIRRORS; do echo "Server = ${m%/}/\$repo/os/\$arch" >> /etc/pacman.d/mirrorlist; done \
 && sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 1/' /etc/pacman.conf

# 1. Ключи pacman: инициализация, затем обновление keyring ДО полного обновления системы
#    (иначе возможны ошибки "signature is unknown trust" / "invalid or corrupted package").
#    Каждый шаг с повторами: при обрыве скачанные файлы докачиваются.
RUN pacman-key --init \
 && pacman-key --populate archlinux \
 && for i in 1 2 3 4 5; do pacman -Sy --noconfirm archlinux-keyring && break || sleep 5; done \
 && for i in 1 2 3 4 5; do pacman -Su --noconfirm --needed base-devel git sudo libarchive pkgfile && break || sleep 5; done \
 && pacman -Scc --noconfirm

# 2. Непривилегированный пользователь для makepkg/AUR + sudo без пароля
RUN useradd -m -u 1000 builder \
 && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder \
 && chmod 440 /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder

# 3. GPG для проверки подписей исходников AUR-пакетов (validpgpkeys)
RUN mkdir -p ~/.gnupg && chmod 700 ~/.gnupg \
 && printf 'keyserver hkps://keys.openpgp.org\nkeyserver-options auto-key-retrieve\n' > ~/.gnupg/gpg.conf

# 4. AUR-хелпер (yay-bin: готовый бинарник, не нужен Go)
RUN git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin \
 && cd /tmp/yay-bin && makepkg -si --noconfirm \
 && rm -rf /tmp/yay-bin ~/.cache/yay

# 5. debtap + предзагруженная база соответствия Debian -> Arch (запекается в образ)
RUN yay -S --noconfirm --needed debtap \
 && sudo debtap -u \
 && sudo pacman -Scc --noconfirm

COPY --chmod=755 convert.sh /usr/local/bin/convert.sh
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/convert.sh"]
