#!/bin/bash
set -e

APP_NAME="coordi-vysor"
VERSION="1.1.0"
ARCH="amd64"
MAINTAINER="achavez <andres.cz.chavez@gmail.com>"
DESCRIPTION="Interfaz gráfica para scrcpy - control de dispositivos Android"
BUNDLE_SRC="build/linux/x64/release/bundle"
DEB_ROOT="build/deb/${APP_NAME}_${VERSION}_${ARCH}"

echo "==> Verificando build..."
if [ ! -f "${BUNDLE_SRC}/scrcpy_gui" ]; then
    echo "Bundle no encontrado. Ejecutando flutter build linux --release..."
    flutter build linux --release
fi

echo "==> Limpiando directorio previo..."
rm -rf "build/deb"
mkdir -p "${DEB_ROOT}/DEBIAN"
mkdir -p "${DEB_ROOT}/usr/lib/${APP_NAME}"
mkdir -p "${DEB_ROOT}/usr/bin"
mkdir -p "${DEB_ROOT}/usr/share/applications"
mkdir -p "${DEB_ROOT}/usr/share/icons/hicolor/256x256/apps"

echo "==> Copiando bundle..."
cp -r "${BUNDLE_SRC}/." "${DEB_ROOT}/usr/lib/${APP_NAME}/"

echo "==> Creando launcher script..."
cat > "${DEB_ROOT}/usr/bin/${APP_NAME}" << 'EOF'
#!/bin/bash
exec /usr/lib/coordi-vysor/scrcpy_gui "$@"
EOF
chmod 755 "${DEB_ROOT}/usr/bin/${APP_NAME}"

echo "==> Copiando ícono..."
cp "assets/logo.png" "${DEB_ROOT}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

echo "==> Creando .desktop entry..."
cat > "${DEB_ROOT}/usr/share/applications/${APP_NAME}.desktop" << EOF
[Desktop Entry]
Name=Coordi Vysor
Comment=${DESCRIPTION}
Exec=/usr/bin/${APP_NAME}
Icon=${APP_NAME}
Terminal=false
Type=Application
Categories=Utility;
EOF

echo "==> Calculando tamaño instalado..."
INSTALLED_SIZE=$(du -sk "${DEB_ROOT}/usr" | cut -f1)

echo "==> Creando control file..."
cat > "${DEB_ROOT}/DEBIAN/control" << EOF
Package: ${APP_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0, libglib2.0-0, libgdk-pixbuf2.0-0
Description: ${DESCRIPTION}
 Interfaz gráfica para controlar dispositivos Android
 mediante scrcpy. Incluye adb y scrcpy integrados.
EOF

echo "==> Creando postinst..."
cat > "${DEB_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
chmod +x /usr/lib/coordi-vysor/scrcpy_gui
chmod +x /usr/lib/coordi-vysor/bin/linux/scrcpy
chmod +x /usr/lib/coordi-vysor/bin/linux/adb
update-desktop-database /usr/share/applications/ 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true
EOF
chmod 755 "${DEB_ROOT}/DEBIAN/postinst"

echo "==> Empaquetando .deb..."
dpkg-deb --build --root-owner-group "${DEB_ROOT}"

DEB_FILE="build/deb/${APP_NAME}_${VERSION}_${ARCH}.deb"
echo ""
echo "✓ Listo: ${DEB_FILE}"
echo "  Instalar: sudo dpkg -i ${DEB_FILE}"
echo "  Lanzar:   coordi-vysor"
