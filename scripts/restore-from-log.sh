#!/bin/zsh
# Devuelve a su ubicación original los elementos que Holgura movió a la Papelera,
# usando cleanup.log. Solo mueve (mv -n): nunca sobrescribe ni borra nada.
#
# Uso:
#   scripts/restore-from-log.sh "2026-10-19T10:35"        # vista previa de lo que se restauraría
#   scripts/restore-from-log.sh "2026-10-19T10:35" --run  # restaurar de verdad
set -euo pipefail

LOG="$HOME/Library/Application Support/Holgura/cleanup.log"
PREFIX="${1:?Indica el prefijo de fecha/hora de la limpieza, p. ej. 2026-10-19T10:35}"
RUN="${2:-}"

restored=0; skipped=0
while IFS=$'\t' read -r date action size original trashed; do
  [[ "$date" == "$PREFIX"* && "$action" == "PAPELERA" ]] || continue
  if [[ ! -e "$trashed" ]]; then
    echo "· ya no está en la Papelera: $trashed"; skipped=$((skipped+1)); continue
  fi
  if [[ -e "$original" ]]; then
    echo "· ya existe el original, se omite: $original"; skipped=$((skipped+1)); continue
  fi
  if [[ "$RUN" == "--run" ]]; then
    mkdir -p "$(dirname "$original")"
    mv -n "$trashed" "$original"
    echo "✓ $original"
  else
    echo "→ $trashed  ⇒  $original"
  fi
  restored=$((restored+1))
done < "$LOG"

if [[ "$RUN" == "--run" ]]; then
  echo "Restaurados: $restored · omitidos: $skipped"
else
  echo "Vista previa: $restored se restaurarían · $skipped omitidos. Añade --run para hacerlo."
fi
