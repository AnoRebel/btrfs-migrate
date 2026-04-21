// Embeds the bash implementation into the Go binary so a single
// executable can be shipped stand-alone. The wizard still prefers an
// on-disk script (for development and for packagers who want to patch
// the script without rebuilding Go), and only falls back to the
// embedded copy when nothing external is found.
//
// Layout inside the binary mirrors the repo:
//
//	scripts/btrfs-migrate.sh
//	scripts/lib/*.sh
//
// Extraction writes the same tree into a fresh tempdir, chmods the
// entrypoint +x, and returns its path. The caller is responsible for
// removing the tempdir when done — see extractedScripts.Cleanup.
//
// Security properties of the writer:
//   - Each embedded path is cleaned, rejected if it contains `..` or
//     becomes absolute, and joined to the destination under a final
//     boundary check so we cannot escape the target directory.
//   - Destination files are created with O_EXCL|O_NOFOLLOW so we never
//     overwrite an attacker-placed symlink.
//   - Destination directories are refused if they are symlinks.
package main

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

//go:embed scripts/btrfs-migrate.sh scripts/lib/*.sh
var embeddedScripts embed.FS

type extractedScripts struct {
	Path string
	Dir  string
}

func (e extractedScripts) Cleanup() {
	if e.Dir != "" {
		_ = os.RemoveAll(e.Dir)
	}
}

func extractScripts() (extractedScripts, error) {
	dir, err := os.MkdirTemp("", "btrfs-migrate-scripts-*")
	if err != nil {
		return extractedScripts{}, fmt.Errorf("mkdtemp: %w", err)
	}
	if err := writeEmbeddedInto(dir); err != nil {
		_ = os.RemoveAll(dir)
		return extractedScripts{}, err
	}
	return extractedScripts{
		Path: filepath.Join(dir, "scripts", "btrfs-migrate.sh"),
		Dir:  dir,
	}, nil
}

// extractScriptsTo materialises the embedded tree into a user-chosen
// directory (the caller owns cleanup — we do not RemoveAll on error).
func extractScriptsTo(dir string) error {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return fmt.Errorf("resolve %s: %w", dir, err)
	}
	// Refuse to plant scripts into a symlinked directory — the link
	// target may be controlled by another user.
	if fi, err := os.Lstat(abs); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to extract into symlinked path: %s", abs)
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", abs, err)
	}
	return writeEmbeddedInto(abs)
}

// safeJoin returns destDir + cleaned(embedPath), ensuring the result
// stays strictly inside destDir. Embed entry names come from compile
// time, not user input — but we defend in depth because destDir may be
// user-controlled and future embeds may grow.
func safeJoin(destDir, embedPath string) (string, error) {
	// embed.FS paths are always forward-slash. Clean drops ./ and ../.
	cleaned := filepath.ToSlash(filepath.Clean(embedPath))
	if cleaned == "." || cleaned == "/" {
		return destDir, nil
	}
	if strings.HasPrefix(cleaned, "../") || cleaned == ".." || strings.Contains(cleaned, "/../") {
		return "", fmt.Errorf("refusing embedded path with .. segment: %q", embedPath)
	}
	if strings.HasPrefix(cleaned, "/") {
		return "", fmt.Errorf("refusing absolute embedded path: %q", embedPath)
	}
	out := filepath.Join(destDir, cleaned)
	// Final boundary check against symlinks inside destDir by comparing
	// cleaned absolute prefixes.
	rel, err := filepath.Rel(destDir, out)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", fmt.Errorf("embedded path escapes destination: %q", embedPath)
	}
	return out, nil
}

// writeFileExclusive writes data to path with O_EXCL|O_NOFOLLOW so we
// never follow or overwrite an existing symlink at the destination. If
// the file already exists and is a regular file we remove it first
// (and re-check it wasn't a symlink between Lstat and remove).
func writeFileExclusive(path string, data []byte, mode os.FileMode) error {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing to write through symlink: %s", path)
		}
		if !fi.Mode().IsRegular() {
			return fmt.Errorf("refusing to overwrite non-regular file: %s", path)
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("remove stale %s: %w", path, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("lstat %s: %w", path, err)
	}
	f, err := os.OpenFile(path,
		os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW,
		mode)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	if _, werr := f.Write(data); werr != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return fmt.Errorf("write %s: %w", path, werr)
	}
	if cerr := f.Close(); cerr != nil {
		return fmt.Errorf("close %s: %w", path, cerr)
	}
	// Re-chmod: O_CREATE honours umask so the effective mode may be
	// narrower than requested. Force explicit mode.
	if err := os.Chmod(path, mode); err != nil {
		return fmt.Errorf("chmod %s: %w", path, err)
	}
	return nil
}

func writeEmbeddedInto(dir string) error {
	// Refuse symlinked destination directory (parents checked by caller).
	if fi, err := os.Lstat(dir); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("destination directory is a symlink: %s", dir)
	}

	return fs.WalkDir(embeddedScripts, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		out, jerr := safeJoin(dir, p)
		if jerr != nil {
			return jerr
		}
		if d.IsDir() {
			if err := os.MkdirAll(out, 0o755); err != nil {
				return err
			}
			return nil
		}
		data, err := embeddedScripts.ReadFile(p)
		if err != nil {
			return fmt.Errorf("read embedded %s: %w", p, err)
		}
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if p == "scripts/btrfs-migrate.sh" {
			mode = 0o755
		}
		return writeFileExclusive(out, data, mode)
	})
}
