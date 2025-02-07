# Maintainer: viable <hi@viable.gg>
pkgname=lifetch
pkgver=0.1.0
pkgrel=1
pkgdesc="Fast system information fetcher written in zig"
arch=('x86_64')
url="https://github.com/nuiipointerexception/lifetch"
license=('MIT')
depends=()
makedepends=('zig')
source=("git+${url}.git")
sha256sums=('SKIP')

build() {
    cd "$pkgname"
    zig build -Doptimize=ReleaseSafe
}

package() {
    cd "$pkgname"
    install -Dm755 zig-out/bin/lifetch "$pkgdir/usr/bin/lifetch"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
} 