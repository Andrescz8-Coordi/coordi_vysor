# Instalación en Linux

## 1. Extraer archivos

```bash
mkdir -p ~/apps/scrcpy_gui
unzip scrcpy_gui_linux.zip -d ~/apps/scrcpy_gui
```

## 2. Dar permisos de ejecución

```bash
chmod +x ~/apps/scrcpy_gui/bundle/scrcpy_gui
chmod +x ~/apps/scrcpy_gui/bundle/bin/linux/scrcpy
chmod +x ~/apps/scrcpy_gui/bundle/bin/linux/adb
```

## 3. Instalar dependencia GTK3 (si no la tienes)

```bash
# Ubuntu / Debian
sudo apt install libgtk-3-0

# Fedora
sudo dnf install gtk3

# Arch
sudo pacman -S gtk3
```

## 4. Agregar a las aplicaciones del sistema

Ejecuta esto en la terminal — detecta tu usuario automáticamente:

```bash
BUNDLE_PATH="$HOME/apps/scrcpy_gui/bundle"

cat > ~/.local/share/applications/scrcpy_gui.desktop << EOF
[Desktop Entry]
Name=Scrcpy GUI
Comment=Interfaz gráfica para scrcpy
Exec=$BUNDLE_PATH/scrcpy_gui
Icon=$BUNDLE_PATH/data/flutter_assets/assets/logo.png
Terminal=false
Type=Application
Categories=Utility;
EOF
```

## 5. Actualizar base de datos de aplicaciones

```bash
update-desktop-database ~/.local/share/applications/
```

Después de esto, la app aparece en el buscador/menú de tu escritorio (GNOME, KDE, XFCE, etc.).

## Ejecutar manualmente (sin instalación)

```bash
cd ~/apps/scrcpy_gui/bundle
./scrcpy_gui
```
