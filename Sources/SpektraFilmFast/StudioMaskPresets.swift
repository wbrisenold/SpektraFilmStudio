import Foundation

struct StudioMaskPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var grade: LocalGradeRecord
    private static let key = "SpektraFilmStudio.maskPresets.v1"
    static var custom: [StudioMaskPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StudioMaskPreset].self, from: data)) ?? []
    }
    static func save(name: String, grade: LocalGradeRecord) {
        var saved = grade
        for index in saved.masks.sources.indices where saved.masks.sources[index].aiRecipe != nil {
            saved.masks.sources[index].raster = nil
        }
        var presets = custom.filter { $0.name != name }
        presets.append(StudioMaskPreset(id: UUID(), name: name, grade: saved))
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
    static var builtIn: [StudioMaskPreset] {
        func make(_ index: Int, _ name: String, _ recipe: AIMaskRecipe, _ configure: (inout ToneSettings) -> Void) -> StudioMaskPreset {
            var tone = ToneSettings(); configure(&tone)
            var grade = LocalGradeRecord(); grade.name = name; grade.tone = tone
            var source = MaskSourceRecord(name: name, kind: .raster)
            source.aiRecipe = recipe; source.feather = 0
            grade.masks.sources = [source]
            var colour = LocalMaskColorSettings()
            switch index {
            case 1: colour.temperature = -12; colour.saturation = 15
            case 2: colour.clarity = 8
            case 3: colour.saturation = -15
            case 4: colour.texture = -35; colour.clarity = -10
            case 5: colour.saturation = -45
            case 6: colour.clarity = 20; colour.saturation = 15
            case 7: colour.temperature = -4; colour.clarity = 5
            case 8: colour.temperature = 12
            case 9: colour.saturation = -20; colour.clarity = -12
            case 10: colour.texture = 15; colour.clarity = 12
            case 11: colour.texture = 20; colour.saturation = 8
            case 12: colour.saturation = -15
            case 13: colour.temperature = 8; colour.saturation = 12
            case 14: colour.temperature = -10; colour.saturation = 10
            case 15: colour.saturation = -20
            case 16: colour.clarity = 20
            case 17: colour.saturation = -12; colour.clarity = -10
            case 18: colour.texture = 12; colour.clarity = 8
            case 19: colour.temperature = 10
            case 20: colour.texture = -15
            case 21: colour.saturation = 10
            case 22: colour.clarity = 15
            default: break
            }
            grade.localColor = colour
            return StudioMaskPreset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, name: name, grade: grade)
        }
        return [
            make(1, "Blue Sky", AIMaskRecipe(kind: .sky)) { $0.exposureEV = -0.3; $0.highlights = -25 },
            make(2, "Brighten Subject", AIMaskRecipe(kind: .subject)) { $0.exposureEV = 0.35; $0.shadows = 15 },
            make(3, "Darken Background", AIMaskRecipe(kind: .background)) { $0.exposureEV = -0.5 },
            make(4, "Smooth Skin", AIMaskRecipe(kind: .people, part: .faceSkin)) { _ = $0 },
            make(5, "Whiten Teeth", AIMaskRecipe(kind: .people, part: .teeth)) { $0.exposureEV = 0.25 },
            make(6, "Pop Eyes", AIMaskRecipe(kind: .people, part: .iris)) { $0.exposureEV = 0.3 },
            make(7, "Brighten Snow", AIMaskRecipe(kind: .landscape, landscape: .snow)) { $0.exposureEV = 0.35; $0.whites = 15 },
            make(8, "Warm Portrait", AIMaskRecipe(kind: .people, part: .faceSkin)) { $0.exposureEV = 0.15 },
            make(9, "Quiet Background", AIMaskRecipe(kind: .background)) { $0.contrast = -10; $0.highlights = -15 },
            make(10, "Portrait Presence", AIMaskRecipe(kind: .people)) { $0.exposureEV = 0.2; $0.shadows = 10 },
            make(11, "Hair Detail", AIMaskRecipe(kind: .people, part: .hair)) { $0.shadows = 15 },
            make(12, "Protect White Clothes", AIMaskRecipe(kind: .people, part: .clothes)) { $0.highlights = -30; $0.whites = -10 },
            make(13, "Rich Foliage", AIMaskRecipe(kind: .landscape, landscape: .vegetation)) { $0.highlights = -10; $0.contrast = 8 },
            make(14, "Clear Water", AIMaskRecipe(kind: .landscape, landscape: .water)) { $0.highlights = -15; $0.contrast = 8 },
            make(15, "Recover Sky", AIMaskRecipe(kind: .sky)) { $0.highlights = -40; $0.whites = -15 },
            make(16, "Mountain Detail", AIMaskRecipe(kind: .landscape, landscape: .mountains)) { $0.contrast = 10; $0.shadows = 12 },
            make(17, "Soft Subject", AIMaskRecipe(kind: .subject)) { $0.highlights = -12; $0.shadows = 8 },
            make(18, "Architecture Detail", AIMaskRecipe(kind: .landscape, landscape: .architecture)) { $0.contrast = 10; $0.shadows = 10 },
            make(19, "Golden Background", AIMaskRecipe(kind: .background)) { $0.highlights = -10 },
            make(20, "Even Body Skin", AIMaskRecipe(kind: .people, part: .bodySkin)) { $0.highlights = -10; $0.shadows = 8 },
            make(21, "Lip Color", AIMaskRecipe(kind: .people, part: .lips)) { $0.contrast = 5 },
            make(22, "Eyebrow Definition", AIMaskRecipe(kind: .people, part: .eyebrows)) { $0.exposureEV = -0.1 }
        ]
    }
}
