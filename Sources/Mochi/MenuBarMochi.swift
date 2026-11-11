import AppKit
import SwiftUI

/// Mochi's menu bar glyphs: a monochrome outline of the app icon (the matcha mochi with
/// headphones) as template images, so macOS tints them like every other menu bar extra (light,
/// dark and tinted menu bars, highlighted while the menu is open).
///
/// Derived from dev/icon-candidates/a-matcha-headphones-icon.png, not drawn by hand: the mochi
/// body and the headphones were segmented from the artwork by colour (GrabCut for the subject,
/// green for the body), the band reduced to its centre line, the ear cups kept as filled shapes,
/// the eyes and smile taken from the dark features, then every edge stroked at an even 1.2 pt
/// from a distance field and area-downsampled. A 16 pt glyph in a 23 x 22 pt image, black plus
/// alpha, at 1x and 2x. The 1x images are pixel-tuned: the eyes are two crisp 2 x 2 dots at full
/// opacity snapped to whole pixels, and the smile is left out because one pixel cannot draw it. Recording adds a microphone
/// badge (SF Symbols' mic.fill, drawn at run time), silenced a slash, each with a knockout gap like
/// the SF Symbols badges.
enum MenuBarMochi {
    static let rest = image(v1x: rest1x, v2x: rest2x)
    /// Recording: the outline with a microphone badge at the bottom right, a third of the glyph,
    /// cut out of the outline with a gap like the SF Symbols badges (the mic is SF Symbols' own).
    static let recording = badged(rest, symbol: "mic.fill")
    static let silenced = image(v1x: off1x, v2x: off2x)

    static let size = NSSize(width: 23, height: 22)

    /// The badge's box, bottom right of the 23 x 22 pt image: 8 pt, about a third of the 16 pt glyph.
    static let badgeRect = NSRect(x: 14.5, y: 0.5, width: 8, height: 8)

    /// `base` with `symbol` in `badgeRect`, after clearing a 1 pt gap around it. Drawn per scale
    /// (1x and 2x get their own pixels), black plus alpha, a template like the others.
    private static func badged(_ base: NSImage, symbol: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: badgeRect.height, weight: .semibold)
        let mic = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            base.draw(in: rect)
            guard let mic else { return true }
            // Fit the symbol in the badge box, keeping its proportions.
            let s = min(badgeRect.width / mic.size.width, badgeRect.height / mic.size.height)
            let drawn = NSRect(x: badgeRect.midX - mic.size.width * s / 2, y: badgeRect.midY - mic.size.height * s / 2,
                               width: mic.size.width * s, height: mic.size.height * s)
            // The gap: the outline under the badge and 1 pt around it is cleared.
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(drawn.insetBy(dx: -1.2, dy: -1.2))
            context.restoreGState()
            let tinted = NSImage(size: drawn.size, flipped: false) { r in
                mic.draw(in: r)
                NSColor.black.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: drawn)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func image(v1x: String, v2x: String) -> NSImage {
        let image = NSImage(size: size)
        for base64 in [v1x, v2x] {
            guard let data = Data(base64Encoded: base64), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    private static let rest1x = "iVBORw0KGgoAAAANSUhEUgAAABcAAAAWCAYAAAArdgcFAAABsUlEQVR4nN3Vy6uNURgG8J+TS4edgSQM1HGLCVFHGRkaSFFKyYhMpAyNTIxIMiAh/4GRdE4yEkO5d5K7U8cluQxcQuyjlWfXl76z7b1PJp76+r613vd91lrP+77r4x9iSgc+SzCIxejHVzzDdTzqdeFtuIEmXuMaLuEqXmb+NrZ3Q9qP8/iCY1iZ+VlYiEbGy3EEn3CxMj8hpuIyHoZ0FU7jeXY6nvcYzmENlmEEVzC93Y5PRYKi7wn8yGJ7ovsA1mIXhmM/E/8XOIuZdeTH4zwcWUax4S8nXY8nkWUo8SfrHHfjbo64Jfp2gnlJaom7g71/OixKiY3nKcnrBgsqsd8jn74Yd2BGvsfwuRLYCtJm7lWSXjANO6vkpSpaGNIbLlS+V1cNW5OMZpLUCwYT/7OusQ7gUI/ELZSmO9gatGQpuJ9kTAal1u/VkS/F5klR/5Z3RZ1hY6qk0SNx6cyP2FRnLCX0NO1cPVEn6MvVMdruflmHt7iF/RnPmcB3di6ufbiJd51U2nwcxoOUVWmWbwl+g/cZN/M8xtF0aVd/okZaeW6uhHL8Qlhy8yEylPd/hl+DGmjRnfkr2gAAAABJRU5ErkJggg=="
    private static let rest2x = "iVBORw0KGgoAAAANSUhEUgAAAC4AAAAsCAYAAAAacYo8AAAEFElEQVR4nO2Za4hVVRTHf9OMzahTqY06IxY56AiazxIVTS0mMJQIURE0wT6YhlIIkkIWifgiUNSwfH2oICjCPogwaC+CfCIKoqkNJWpZajM5jqbOeGXpf8PmeM695965d27E/cPmDPectfbae73XQAEFxEIR2cdDQAegM3ADuA20/NcE7wiMB14EBgD9gd5AifdNK/AHcBo4DnwDfAs0kwcMBLYBTUAig9UMfAIMba8brwTWArMCtFeAI8AvwCngb920mU0XoB9QAwwHenh0d4AvgcXAOXKEl4BL3q1dAz6SqZhNx0EJMAbYADR6vBqAmbkQ+g3dYELOtgmoCPmulw4yFXgVmA68ADwVot2u0t4t8bXbfyebQi8UU2P+O/Cc964UmAZ8DlxMYddmPl8DsxVxHJ4F6j3hl2ZD6FqFMmN6AujjRZMlKYS9k+IQ7wGPil934JjemWZfaYvQlQpjCQloYc4wwbshJ+CvMh+z02FywFKZ0yBp5QPgZOBAF4DJ4tsT+E2//wU8kYnQr8th3AbmmEiNTgMmQJ1sOB2Mlsm4A9hzlXxggrfnVeCtdBiP9xzRrXHASm+zi21VJ/fN0N2wrY06VNDcJsZlOFEE9VJZi9R9TswOAlVkB48rixrff7RPi8LuKclhkSmtSLJV6jLi+bqh94FysosyYJlsfZ60bTniY+DtdJLkhyFRwE6faxTrooJ7fxaHeGxEGMtZOg5kVef4wWVFXFJ8EUF4gPbB8Yj9dyUj6gRcjyDcnITOiqi+MQWrjigVHNZF7H9TJUIonk+S6aJC31AVS2Ze61MI/a6+u654na4MLlE9gNciCJqU4sOwxvvOBHJO5hqJJxU18MJpAtgewa9EIThMjjf9D61edrD0HoY6tWBh+EG3aPhez09V1+xQKWD0hu/0THh/B2HO+VXEuz8jfr93iJ0hmStVSh8JzPC08rIaC1cCu5uymn1KoLoMw6iQ296Tqua3l0fjenMSlKoHNcfNBPs8GU575pYUVt3tB/Z6FWF7o0Yh+Jjql9iokGPlE92Ax9IhKJMj3NTJ84EqFV0WYR4J+8CPKg6d1Qg8DDxNfjBE3VH3qMQTJnijogF5tPFeeppzXo4reKtqccNg8oNhel7wElss7PC6+rgzk2yhGDibTknro9Yrb9Pq+7KAuV4Mn5QJgx9F/K+yYXtgkuaKtu/hTIey/eQYbtaxPYfhsRrY4jXpDRqsZoxngPOB2uUQsFpN7OAMetAOGiyZFpcDPwWmCrbfiFRMimJmsBXAnIiawXXoV9QzNit5OZSpSbFE0kXLn5873FJQWBYVAjOFJaUFwO7AsKgt65pqokWanOX8PxJFGpHVaBLbUxmuXMvPD63SggnpNGNh9mfgjN4XUEAB/xfcBTo1g0gy3rFTAAAAAElFTkSuQmCC"
    private static let off1x = "iVBORw0KGgoAAAANSUhEUgAAABcAAAAWCAYAAAArdgcFAAACEklEQVR4nNXVSYjOYRwH8A9ZwtsccDCU7NkiiqLXcnJzsOWuHCw15cLFxYVRkwuFnBjLVRrJSYiDhBiSZciS7LKOmNGj38vj731n3ouDb/37P//n+W3P97f8+Yfok60HorOKzHjMwTgMwhd04BLu1OMkGX6P9dneSlxGF57hHE7hLJ7G/lWsrsfBKnzGdszHW7RgSpwPwUiU4nsSmvEBJ7L9mliI1ziIwZiGvXgQkXbH+zEOYBYmoh1nMKCW4cRnE6biIU5jOo5gbfA+FrOxBifxDfsiH0+wP4L6C7tCeA9G4RquoLGHm87DvaClLfR3Vw77ZoI3cBOLI+IFeIULGe9FXAwHrRgT9CQbf2B0lFh3PCl5gsPD4aTcww0aM92vQd8vbMkOH1Wpop34hOWxV0lujo7MxtaclhmZUFtB6WgkazOOYSM2hYMcx7P1zPxgWSSjKzishRVxg+ZCd4tqSvrfqzVWimxbD4YrKEcOWqvUdUuFkmK13Ipk9Ibz4aActd6QnSX6rlczPgFLezX9O5A0IobFrEljoULv5GrG26O+S3U6SMNrEV5EL6TOfpdHnqM/7kc75057Q9I7FHlIjdevluBcvIy2b4rvoTVkG2JwrcMS7IipmkZ1TYwIwdtRVt3xE0mRPY+p2Rlll5670WSpqzdEqf6ktlirRZSilYeHcqIrGfyINzE907uok2b8f4wfBE6E4ibGU2sAAAAASUVORK5CYII="
    private static let off2x = "iVBORw0KGgoAAAANSUhEUgAAAC4AAAAsCAYAAAAacYo8AAAEtklEQVR4nO2ZC4hWVRDHf9uu7K5pWVpmlJW02wtty16SoYmFVkhURk+jIiroIUZFYUUR9CAK1LAoCyLoTWKRQQ+KyIwoEjY0zQoqq02zzV11W3e/GPgfGO7ee79773c3CL4/XGS/e2fOnJk5M/85Qh11ZEID5WMvYASwN7AL6Af2/BeGT9BiWzPItwIzgLOAY4GjgEOAJvfNAPArsBHoBD4APgR6S9wHh0rhn8DMlO+OA54FdgCVAk8v8ALQUZbHzVsbFOY+4GrgJff+IOBR4IqI7DbgK+A74FttfEBpMwZoA9qBE4EDndwg8BpwO/ATNeI0oEueGZBSw75SHrzWAzylVLGczoIm4HRgCfCX07UduJwS0CbvVeSVJfLedOB3YBkwLkbuYG3kIuBK4GJgFnB4THT3U/T+cessLsN4C+nnzitv6DC2uG+agflKp9+q5LWlz0pggVIx4CRgszP+rjKMtwXecot/CozVuwurGDtYZRP3AftI1wHAOpee59ditB3EU4BG4Gm3qB3eI4BRwGoZ+IPSx/L0BEWrWek0WVF5DFgf2dAvwHlabzzwo37vUoXLjet1YOwAztNvi92iVpen6rBNy6l7mlIm6LJ/H9IZmOk29TewMI/iGQpXUNAvIw1XqUxWVMPnUhyznYftWapNRdNtTlaFcySwWSHbo3DfLK+cDXRLsVWEa2swfqy6aEU6J2u9P9QPBlWZMsOMfEbhMuEb5aGQFh3Kz+CV+2swvgW4R7l+g6Ldo3N1Zx4+9WRMFbDdR3EY8I37ZkWEo+RFoxwVXfvFLMLTE8pYUju2JvKx+261qk0RNClN4sqnkbhUvJogaI0oCVb2XnHffqlSWgSdCeu/nSY0EtiZILi8iqeMDjzuovU9cHTMt5MSqELAEwnr9ym6sTgzpdMldbIOcZdL9PdCV0q3KvUC7tXGdqZQ5jQbQqMagmsSBHaIo8ThEdemb9Nv8zX5VGSkUQPDIrcpO8hJ0QvMNPrcmmT43ASB15MEgHOcMe+4388QR6/owIVFLwV2i88nYXmCHSGqQ2B5+mZM5zJamoZTpbTV6TEcIw4T9BhXadBoWG0eiBr9XjXOby+/znqaM2CCJqOg72VVoWr4zMlsjFDpRBi7Wwu8r1GuVowG3nWGfKRxLg3tKsHr8pI4K1kTKQ8Wyeed8Z0Z9O+vcTEzWlTi+rTzMvGAq/U/A8enpFi3KoxFLDNjC565gPJxnZszu0Xe4hhqsGFiHrITFN/C8OBcdyfTp8E6rqcMqqNnxnoJ2qXPcOFkN7NaL7jbvVtahdwl4jkJbslxZ1IEk0SZPSdqdHc7mSitx2x3iHLNfQUwDljjjF+l9GjT5VFufCJFu93APFxojXTttbqyKIQ2MbyQgyuGoTwGjFSKLHOR3gQcSUFMVb313OUL4GENsVMKTDwjdC8zT3V9jWbMUHrvcMStS1xoCLIMotbBHtTNbRxnCPV4m2bGXpW4gBZ51BrJGD1xs+kutXdr85epQDRL3xQNJ4Vgt1M3ib5uTyH8eZ4ecaJFMePeLK3Tr/v4Uv4rpUFXZO26iR2v0WqUnkBtUdh7ZWS3IrNFV3mb9J6U1j9aDLGOOurgf4B/AckW0h0ck99IAAAAAElFTkSuQmCC"
}

/// The menu bar item's label: Mochi's outline, with the mic badge while recording. Attention and
/// failure swap in an SF Symbol so the state is readable from the menu bar.
struct MenuBarLabel: View {
    let recording: Bool
    let paused: Bool
    let health: RecordingHealth?
    let timer: String?

    var body: some View {
        HStack(spacing: 4) {
            switch health {
            case .broken?:
                Image(systemName: "exclamationmark.octagon.fill")
            case .attention?:
                Image(systemName: "exclamationmark.triangle.fill")
            default:
                Image(nsImage: recording && !paused ? MenuBarMochi.recording : MenuBarMochi.rest)
            }
            if let timer { Text(timer).monospacedDigit() }
        }
        .accessibilityLabel(recording ? "Mochi, recording" : "Mochi")
    }
}
