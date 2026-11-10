// Fills the download cards from releases.json, which make deploy-android and deploy-windows extend.

const TAG = /^([a-z]+)-v(\d+\.\d+\.\d+)(?:-(\d+))?$/;

// Set from REPO_URL when the image is built.
const REPO = document.documentElement.dataset.repo;

const label = (build) => build.version + (build.number ? ` (Build ${build.number})` : "");

const details = (build) => new Date(build.published).toLocaleDateString("de-DE");

function buildsOf(releases, platform, extension) {
  return releases.flatMap((release) => {
    const match = TAG.exec(release.tag);
    if (!match || match[1] !== platform || !release.asset.endsWith(extension)) return [];
    return [{
      version: match[2],
      number: match[3],
      published: release.published,
      page: `${REPO}/releases/tag/${release.tag}`,
      file: `${REPO}/releases/download/${release.tag}/${release.asset}`,
    }];
  });
}

function olderRow(build) {
  const row = document.createElement("li");
  const download = document.createElement("a");
  download.href = build.file;
  download.textContent = label(build);
  const meta = document.createElement("small");
  meta.textContent = details(build);
  const release = document.createElement("a");
  release.href = build.page;
  release.textContent = "Release";
  row.append(download, meta, release);
  return row;
}

function fill(card, releases) {
  const status = card.querySelector("[data-status]");
  const [latest, ...older] = buildsOf(releases, card.dataset.platform, card.dataset.extension);
  if (!latest) {
    status.textContent = "Noch keine Version verfügbar.";
    return;
  }
  status.textContent = "";
  const version = document.createElement("b");
  version.textContent = label(latest);
  status.append("Aktuell: ", version, `, ${details(latest)}`);

  const download = card.querySelector("[data-download]");
  download.href = latest.file;
  download.hidden = false;

  if (older.length > 0) {
    card.querySelector("[data-older] ul").append(...older.map(olderRow));
    card.querySelector("[data-older]").hidden = false;
  }
}

async function load() {
  const cards = document.querySelectorAll("[data-platform]");
  try {
    const response = await fetch("releases.json");
    if (!response.ok) throw new Error(response.statusText);
    const releases = await response.json();
    cards.forEach((card) => fill(card, releases));
  } catch {
    cards.forEach((card) => {
      card.querySelector("[data-status]").textContent = "Die Downloads konnten nicht geladen werden.";
    });
  }
}

load();
