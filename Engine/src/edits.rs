//! Recipes and desktop edit documents, with the desktop rules
//! (x3fuse src-tauri edits.rs and editor.rs at 737688f).
use crate::{invalid, Error, Result, X3F_ERR_CONFLICT, X3F_ERR_UNSUPPORTED};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use x3f_render::{EditRecipe, FilmSettings, STOCKS_JSON};

/// The largest edit document the desktop reads.
pub const JSON_LIMIT: usize = 1024 * 1024;
const DOCUMENT_VERSION: u32 = 2;
/// JavaScript's largest safe integer. The desktop rejects larger revisions.
const MAX_REVISION: u64 = 9_007_199_254_740_991;

/// Parses a full recipe. A missing key takes `EditRecipe::default()`.
pub fn parse(json: &str) -> Result<EditRecipe> {
    let recipe: EditRecipe =
        serde_json::from_str(json).map_err(|e| invalid(format!("Recipe: {e}")))?;
    recipe.validate().map_err(invalid)?;
    Ok(recipe)
}

pub fn canonical(recipe: &EditRecipe) -> String {
    serde_json::to_string(recipe).expect("a recipe serializes")
}

fn value(recipe: &EditRecipe) -> Value {
    serde_json::to_value(recipe).expect("a recipe serializes")
}

fn from_value(value: Value) -> Result<EditRecipe> {
    let recipe: EditRecipe =
        serde_json::from_value(value).map_err(|e| invalid(format!("Recipe: {e}")))?;
    recipe.validate().map_err(invalid)?;
    Ok(recipe)
}

/// An object merges key by key. Any other value replaces the target.
fn merge(target: &mut Value, patch: Value) {
    match (target, patch) {
        (Value::Object(target), Value::Object(patch)) => {
            for (key, value) in patch {
                match target.get_mut(&key) {
                    Some(old) => merge(old, value),
                    None => {
                        target.insert(key, value);
                    }
                }
            }
        }
        (target, patch) => *target = patch,
    }
}

pub fn patch(recipe: &str, patch: &str) -> Result<EditRecipe> {
    let patch: Value = serde_json::from_str(patch).map_err(|e| invalid(format!("Patch: {e}")))?;
    if !patch.is_object() {
        return Err(invalid("Patch must be a JSON object"));
    }
    let mut value = value(&parse(recipe)?);
    merge(&mut value, patch);
    from_value(value)
}

/// True when `recipe` is the photo's `defaults` (editor.rs `matches_defaults`).
/// With `legacy`, also the default film with the as-shot crop and seed that
/// version 1 documents saved for every opened photo.
pub fn matches_defaults(recipe: &EditRecipe, defaults: &EditRecipe, legacy: bool) -> bool {
    let recipe = recipe.pixels();
    recipe == *defaults
        || legacy
            && recipe
                == EditRecipe {
                    film: Some(FilmSettings {
                        grain_params: None,
                        halation_params: None,
                        ..Default::default()
                    }),
                    crop: defaults.crop,
                    seed: defaults.seed,
                    ..Default::default()
                }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stock {
    index: u32,
    key: String,
    name: String,
    is_paper: bool,
    is_positive: bool,
    #[serde(default)]
    monochrome: bool,
    #[serde(default, deserialize_with = "text")]
    antihalation: String,
    #[serde(default, deserialize_with = "text")]
    target_paper_key: String,
    #[serde(default, deserialize_with = "text")]
    r#use: String,
}

/// A string, with null as empty.
fn text<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}

fn stocks() -> Vec<Stock> {
    serde_json::from_str(STOCKS_JSON).expect("bundled stock list")
}

/// LookPicker.tsx `family`.
fn family(stock: &Stock) -> &'static str {
    if stock.monochrome {
        "bwFilm"
    } else if stock.is_positive {
        "slideFilm"
    } else if stock.target_paper_key == "kodak_2383" {
        "cinemaFilm"
    } else {
        "negativeFilm"
    }
}
const FAMILIES: [&str; 4] = ["negativeFilm", "slideFilm", "cinemaFilm", "bwFilm"];

/// LookPicker.tsx `paper`: the stock's own paper, else the current paper when
/// it has the same model (color or black and white), else the first such paper.
fn paper(stocks: &[Stock], stock: &Stock, current: u32) -> u32 {
    let papers = || stocks.iter().filter(|s| s.is_paper);
    papers()
        .find(|p| p.key == stock.target_paper_key)
        .or_else(|| papers().find(|p| p.index == current && p.monochrome == stock.monochrome))
        .or_else(|| papers().find(|p| p.monochrome == stock.monochrome))
        .map_or(current, |p| p.index)
}

/// spektrafilm grain RMS per stock (x3fuse src/shared/film-grain.json at 737688f).
const GRAIN_JSON: &str = include_str!("../resources/film-grain.json");

/// editor.ts `filmGrainDefaults(...).rmsGranularity`.
fn grain_rms(key: &str) -> Value {
    let rms: serde_json::Map<String, Value> =
        serde_json::from_str(GRAIN_JSON).expect("bundled grain list");
    rms.get(key).cloned().unwrap_or(json!([6., 8., 10.]))
}

pub fn catalog() -> String {
    let stocks = stocks();
    let default = value(&EditRecipe::default())["film"].clone();
    let current = FilmSettings::default().paper;
    let mut films: Vec<&Stock> = stocks.iter().filter(|s| !s.is_paper).collect();
    films.sort_by_key(|s| FAMILIES.iter().position(|f| *f == family(s)));
    json!({
        "films": films.iter().map(|s| json!({
            "index": s.index,
            "key": s.key,
            "name": s.name,
            "family": family(s),
            "isPositive": s.is_positive,
            "monochrome": s.monochrome,
            "antihalation": s.antihalation,
            "use": s.r#use,
            "paper": paper(&stocks, s, current),
        })).collect::<Vec<_>>(),
        "papers": stocks.iter().filter(|s| s.is_paper).map(|s| json!({
            "index": s.index,
            "key": s.key,
            "name": s.name,
            "monochrome": s.monochrome,
        })).collect::<Vec<_>>(),
        "defaultFilm": default,
    })
    .to_string()
}

/// The look picker of the desktop editor (LookPicker.tsx at 737688f) for a
/// camera profile id or a film stock key.
pub fn apply_look(recipe: &str, look: &str) -> Result<EditRecipe> {
    let recipe = parse(recipe)?;
    let mut value = value(&recipe);
    let filter = value["monochrome"]["filter"]
        .as_str()
        .unwrap_or("neutral")
        .to_owned();
    let stocks = stocks();
    if let Some(stock) = stocks.iter().find(|s| !s.is_paper && s.key == look) {
        let default_film = serde_json::to_value(FilmSettings::default()).expect("film serializes");
        let mut film = if value["film"].is_null() {
            default_film.clone()
        } else {
            value["film"].clone()
        };
        let same = !value["film"].is_null() && film["film"] == stock.index;
        if !same {
            let boost = if stock.antihalation == "no" {
                json!({"boostEv": 5., "boostRange": 0.7, "protectEv": 4.})
            } else {
                json!({"boostEv": 0., "boostRange": 0.3, "protectEv": 4.})
            };
            if film["halationParams"].is_null() {
                // filmHalationDefaults
                let size = if stock.r#use == "cine" { 50. } else { 65. };
                let strength = match stock.antihalation.as_str() {
                    "no" => json!([0.3, 0.1, 0.015]),
                    "weak" => json!([0.08, 0.02, 0.]),
                    _ => json!([0.015, 0.005, 0.]),
                };
                film["halationSizeRgb"] = json!([size, size, size]);
                film["halationStrengthRgb"] = strength;
            } else {
                merge(&mut film["halationParams"], boost.clone());
            }
            if stock.antihalation == "no" {
                film["halation"] = json!(true);
                if film["halationParams"].is_null() {
                    film["halationParams"] = default_film["halationParams"].clone();
                }
                merge(&mut film["halationParams"], boost);
            }
            if film["grainParams"].is_object() {
                let grain = film["grainParams"].as_object_mut().unwrap();
                grain.remove("rmsBase");
                grain.insert("rmsGranularity".into(), grain_rms(&stock.key));
            }
        }
        let current = film["paper"].as_u64().unwrap_or(0) as u32;
        film["film"] = json!(stock.index);
        film["paper"] = json!(paper(&stocks, stock, current));
        film["negative"] = json!(stock.is_positive);
        value["film"] = film;
        value["cameraProfile"] = Value::Null;
        value["rawColor"] = Value::Null;
        const FILM_FILTERS: [&str; 5] = ["neutral", "yellow", "orange", "red", "green"];
        value["monochrome"] = if stock.monochrome {
            let filter = if FILM_FILTERS.contains(&filter.as_str()) {
                filter.as_str()
            } else {
                "neutral"
            };
            json!({ "filter": filter })
        } else {
            Value::Null
        };
        return from_value(value);
    }
    // Anything else is a camera profile id; validate rejects an unknown one.
    {
        value["film"] = Value::Null;
        value["cameraProfile"] = json!(look);
        value["rawColor"] = Value::Null;
        value["monochrome"] = if look == "Monochrome" {
            json!({ "filter": filter })
        } else {
            Value::Null
        };
        if value["effects"].is_null() {
            // CAMERA_EFFECTS: generic effects with grain and halation on.
            let mut effects = serde_json::to_value(x3f_render::EffectsSettings::default())
                .expect("effects serialize");
            effects["grain"] = json!(true);
            effects["halation"] = json!(true);
            value["effects"] = effects;
        }
        from_value(value).map_err(|_| invalid(format!("Unknown look {look}")))
    }
}

/// The desktop edit document (edits.rs `Document`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Document {
    pub version: u32,
    pub source_revision: String,
    pub revision: u64,
    pub updated_ms: u64,
    pub recipe: EditRecipe,
}

impl Document {
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("a document serializes")
    }
}

pub fn check_revision(revision: u64) -> Result<()> {
    if (1..=MAX_REVISION).contains(&revision) {
        Ok(())
    } else {
        Err(invalid("Invalid edit revision"))
    }
}

/// Parses a document without source checks. Versions newer than 2 are
/// unsupported, as on the desktop.
pub fn parse_document(json: &str) -> Result<Document> {
    if json.len() > JSON_LIMIT {
        return Err(invalid("Edit document exceeds 1 MiB"));
    }
    // Read the version first, so that a newer document reports as newer.
    let version = serde_json::from_str::<Value>(json)
        .map_err(|e| invalid(format!("Edit document: {e}")))?["version"]
        .as_u64();
    if version.is_some_and(|v| v > u64::from(DOCUMENT_VERSION)) {
        return Err(Error(
            X3F_ERR_UNSUPPORTED,
            "Unsupported edit version; update X3Fuse. The file has been preserved.".into(),
        ));
    }
    let document: Document =
        serde_json::from_str(json).map_err(|e| invalid(format!("Edit document: {e}")))?;
    if !(1..=DOCUMENT_VERSION).contains(&document.version) {
        return Err(invalid("Unsupported edit version"));
    }
    check_revision(document.revision)?;
    document.recipe.validate().map_err(invalid)?;
    Ok(document)
}

/// edits.rs `check_previous`.
pub fn check_previous(
    previous: &Document,
    source_revision: &str,
    recipe: &EditRecipe,
    revision: u64,
) -> Result<()> {
    if previous.source_revision != source_revision {
        return Err(Error(
            X3F_ERR_CONFLICT,
            "Source contents changed; reopen the photo before saving".into(),
        ));
    }
    if previous.revision > revision {
        return Err(Error(
            X3F_ERR_CONFLICT,
            "A newer edit revision is already saved".into(),
        ));
    }
    if previous.revision == revision && previous.recipe != *recipe {
        return Err(Error(
            X3F_ERR_CONFLICT,
            "Conflicting edit revision; reload before saving".into(),
        ));
    }
    Ok(())
}

pub fn new_document(
    source_revision: &str,
    recipe: EditRecipe,
    revision: u64,
    previous_ms: u64,
) -> Result<Document> {
    check_revision(revision)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| invalid(e.to_string()))?
        .as_millis()
        .min(u128::from(u64::MAX)) as u64;
    Ok(Document {
        version: DOCUMENT_VERSION,
        source_revision: source_revision.into(),
        revision,
        updated_ms: now.max(previous_ms.saturating_add(1)),
        recipe,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sparse desktop recipe takes `EditRecipe::default()`: film on,
    /// no camera profile, sharpen 0, seed 0.
    #[test]
    fn sparse_recipe_takes_desktop_defaults() {
        let recipe = parse(r#"{"exposure": 1.5}"#).unwrap();
        assert_eq!(
            recipe,
            EditRecipe {
                exposure: 1.5,
                ..Default::default()
            }
        );
        assert_eq!(recipe.film, Some(FilmSettings::default()));
        assert_eq!(recipe.camera_profile, None);
        assert_eq!(recipe.sharpen, 0.);
        assert_eq!(recipe.seed, 0);
        assert_eq!(recipe.denoise, 10);
        // Canonical JSON round-trips to the same value.
        assert_eq!(parse(&canonical(&recipe)).unwrap(), recipe);
        assert!(parse(r#"{"noSuchKey": 1}"#).is_err());
        assert!(parse(r#"{"exposure": 9}"#).is_err());
        // Integers stay integers.
        let text =
            canonical(&parse(r#"{"seed": 4294967295, "rotation": 1, "denoise": 0}"#).unwrap());
        assert!(
            text.contains(r#""seed":4294967295"#) && text.contains(r#""rotation":1"#),
            "{text}"
        );
    }

    #[test]
    fn patch_merges_objects_and_replaces_other_values() {
        let base = canonical(&EditRecipe {
            camera_profile: Some("Standard".into()),
            seed: 7,
            ..Default::default()
        });
        let r = patch(&base, r#"{"film": {"film": 5}, "exposure": 1}"#).unwrap();
        let film = r.film.clone().unwrap();
        assert_eq!(film.film, 5);
        assert_eq!(film.paper, FilmSettings::default().paper);
        assert_eq!((r.exposure, r.seed), (1., 7));
        assert_eq!(r.camera_profile.as_deref(), Some("Standard"));
        assert_eq!(patch(&base, r#"{"film": null}"#).unwrap().film, None);
        assert!(patch(&base, r#"{"film": {"bogus": 1}}"#).is_err());
        assert!(patch(&base, "[]").is_err());
    }

    #[test]
    fn looks_follow_the_desktop_picker() {
        let base = canonical(&EditRecipe {
            camera_profile: Some("Standard".into()),
            film: None,
            ..Default::default()
        });
        let catalog: Value = serde_json::from_str(&catalog()).unwrap();
        let films = catalog["films"].as_array().unwrap();
        assert!(!films.is_empty());
        assert_eq!(films[0]["family"], "negativeFilm");
        for film in films {
            let key = film["key"].as_str().unwrap();
            let r = apply_look(&base, key).unwrap();
            let settings = r.film.unwrap();
            assert_eq!(
                settings.film as u64,
                film["index"].as_u64().unwrap(),
                "{key}"
            );
            assert_eq!(
                settings.paper as u64,
                film["paper"].as_u64().unwrap(),
                "{key}"
            );
            assert_eq!(settings.negative, film["isPositive"].as_bool().unwrap());
            assert_eq!(r.camera_profile, None);
            assert_eq!(
                r.monochrome.is_some(),
                film["monochrome"].as_bool().unwrap()
            );
            if film["antihalation"] == "no" {
                assert!(settings.halation);
                assert_eq!(settings.halation_params.unwrap().boost_ev, 5.);
            }
        }
        // Back to a camera look: film off, effects on.
        let filmed = canonical(&apply_look(&base, "kodak_portra_400").unwrap());
        let camera = apply_look(&filmed, "Vivid").unwrap();
        assert_eq!(camera.film, None);
        assert_eq!(camera.camera_profile.as_deref(), Some("Vivid"));
        let effects = camera.effects.unwrap();
        assert!(effects.grain && effects.halation);
        assert!(apply_look(&base, "nope").is_err());
    }

    #[test]
    fn documents_follow_desktop_rules() {
        let recipe = EditRecipe::default();
        let doc = new_document(&"a".repeat(64), recipe.clone(), 3, 0).unwrap();
        let json = doc.to_json();
        let back = parse_document(&json).unwrap();
        assert_eq!(back.recipe, recipe);
        assert_eq!(back.revision, 3);
        // Unknown keys, bad revisions, newer versions.
        assert!(
            parse_document(&json.replacen("\"revision\"", "\"extra\": 1, \"revision\"", 1))
                .is_err()
        );
        assert!(parse_document(&json.replace("\"revision\": 3", "\"revision\": 0")).is_err());
        let newer = parse_document(&json.replace("\"version\": 2", "\"version\": 3")).unwrap_err();
        assert_eq!(newer.0, X3F_ERR_UNSUPPORTED);
        assert!(parse_document(&" ".repeat(JSON_LIMIT + 1)).is_err());
        // check_previous
        let src = "a".repeat(64);
        assert!(check_previous(&doc, &src, &recipe, 3).is_ok());
        assert!(check_previous(&doc, &src, &recipe, 4).is_ok());
        assert_eq!(
            check_previous(&doc, &src, &recipe, 2).unwrap_err().0,
            X3F_ERR_CONFLICT
        );
        let other = EditRecipe {
            exposure: 1.,
            ..Default::default()
        };
        assert_eq!(
            check_previous(&doc, &src, &other, 3).unwrap_err().0,
            X3F_ERR_CONFLICT
        );
        assert_eq!(
            check_previous(&doc, &"b".repeat(64), &recipe, 4)
                .unwrap_err()
                .0,
            X3F_ERR_CONFLICT
        );
        // updatedMs never goes back.
        let later = new_document(&src, recipe, 4, u64::MAX - 5).unwrap();
        assert_eq!(later.updated_ms, u64::MAX - 4);
    }
}
