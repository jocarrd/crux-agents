pub const LANGUAGE: &str = "en";

pub const SUMMARY: &str = "Summary";
pub const CHANGES: &str = "Changes";
pub const TESTED: &str = "How it was tested";
pub const NOTES: &str = "Notes for reviewers";
pub const SCREENSHOTS: &str = "Screenshots";

pub const OPENED_WITHOUT_GATE: &str = "Opened without the usual checks, at explicit request.";
pub const SCREENSHOTS_REVIEWED: &str = "Reviewed at desktop, tablet and mobile widths.";
pub const SCREENSHOTS_CAPTION: &str = "Before on the left, after on the right.";

pub fn render(sections: &[(&str, String)]) -> String {
    sections
        .iter()
        .filter(|(_, text)| !text.trim().is_empty())
        .map(|(title, text)| format!("## {title}\n\n{}\n", text.trim_end()))
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn summary_from_title(title: &str) -> String {
    let without_type = crate::regex!(r"^[a-z]+(\([^)]*\))?!?:\s*").replace(title.trim(), "");
    let mut chars = without_type.chars();
    let Some(first) = chars.next() else { return String::new() };
    let sentence = format!("{}{}", first.to_uppercase(), chars.as_str());
    if sentence.ends_with('.') {
        sentence
    } else {
        format!("{sentence}.")
    }
}

pub fn is_english(text: &str) -> bool {
    !crate::regex!(r"(?i)[¿¡ñáéíóú]|\b(que|para|los|las|una|pero|también|el|la|del|con|sin)\b").is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_sections_are_left_out() {
        let body = render(&[(SUMMARY, "Adds the form.".into()), (NOTES, "  ".into())]);
        assert_eq!(body, "## Summary\n\nAdds the form.\n");
    }

    #[test]
    fn the_summary_drops_the_commit_type() {
        assert_eq!(summary_from_title("feat(api): send the contact form"), "Send the contact form.");
        assert_eq!(summary_from_title("Fix the menu."), "Fix the menu.");
    }

    #[test]
    fn text_in_spanish_is_told_apart() {
        assert!(is_english("Borders follow the UN map"));
        assert!(!is_english("Pendientes de la web antes de enseñarla"));
    }
}
