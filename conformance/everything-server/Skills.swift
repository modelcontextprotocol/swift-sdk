import Foundation
import MCP

// SEP-2640 fixtures: the skills of the `sep-2640-*` server scenarios, served
// from memory with directory reads.

private func file(_ text: String) -> Data { Data(text.utf8) }

private let pdfProcessing = """
    ---
    name: pdf-processing
    description: Extract, fill, and assemble PDF documents
    license: Apache-2.0
    metadata:
      version: "2.1.0"
      formats: [pdf, docx]
    ---

    # PDF processing

    Fill a form with the fields in [references/FORMS.md](references/FORMS.md), then pick a
    template from `templates/`. Extract text with `scripts/extract.py`.
    """

private let refunds = """
    ---
    name: refunds
    description: Process customer refund requests per company policy
    ---

    # Refunds

    Answer the customer with the template in `examples/email.md`.
    """

/// The skills of the fixture: one at the root of the namespace, with
/// nested directories, and one under a prefix.
let conformanceSkills: InMemorySkillCatalog = {
    do {
        return InMemorySkillCatalog([
            try SkillPackage(
                path: "pdf-processing",
                files: [
                    "SKILL.md": file(pdfProcessing),
                    "references/FORMS.md": file("# Forms\n\nName, address, signature.\n"),
                    "scripts/extract.py": file("import sys\nprint(open(sys.argv[1], 'rb').read()[:100])\n"),
                    "templates/invoice.md": file("# Invoice\n"),
                    "templates/purchase-order.md": file("# Purchase order\n"),
                    "templates/regional/eu-invoice.md": file("# EU invoice\n"),
                ]),
            try SkillPackage(
                path: "acme/billing/refunds",
                files: [
                    "SKILL.md": file(refunds),
                    "examples/email.md": file("Dear customer, your refund is on its way.\n"),
                ]),
        ])
    } catch {
        fatalError("The fixture skills are invalid: \(error)")
    }
}()
