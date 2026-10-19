#[test]
fn unicode_whitespace_method_remains_parseable() {
    let src = "classDiagram\n class 犬 {\n +String\u{3000}吠える()\n }\n";
    let result = std::panic::catch_unwind(|| mermaid_text::parser::class::parse(src));
    assert!(
        result.is_ok(),
        "valid Unicode whitespace method must not panic"
    );
    let diagram = result
        .unwrap()
        .expect("valid typed-before method must parse");
    assert_eq!(diagram.classes.len(), 1);
    assert_eq!(diagram.classes[0].members.len(), 1);
    match &diagram.classes[0].members[0] {
        mermaid_text::class::Member::Method(method) => {
            assert_eq!(method.name, "吠える");
            assert_eq!(method.return_type.as_deref(), Some("String"));
        }
        other => panic!("expected method, got {other:?}"),
    }
}
#[test]
fn malformed_method_returns_error() {
    let src = "classDiagram\n class 犬 {\n +吠える)(\n }\n";
    let result = std::panic::catch_unwind(|| mermaid_text::parser::class::parse(src));
    assert!(
        result.is_ok(),
        "malformed method must return an error, not panic"
    );
    match result
        .unwrap()
        .expect_err("malformed method must be rejected")
    {
        mermaid_text::Error::ParseError(message) => assert_eq!(
            message,
            "method closing `)` precedes opening `(`: \"吠える)(\""
        ),
        other => panic!("unexpected error: {other:?}"),
    }
}

#[test]
fn er_unicode_relationship_separators_preserve_the_exact_relationship() {
    for src in [
        "erDiagram\n顧客\u{3000}||--o{ 注文 : places",
        "erDiagram\n顧客 ||--o{\u{3000}注文 : places",
    ] {
        let result = std::panic::catch_unwind(|| mermaid_text::parser::er::parse(src));
        assert!(result.is_ok(), "Unicode ER separator must not panic: {src}");
        let diagram = result.unwrap().expect("relationship must parse");
        assert_eq!(diagram.entities.len(), 2);
        assert_eq!(diagram.relationships.len(), 1);
        assert_eq!(diagram.relationships[0].from, "顧客");
        assert_eq!(diagram.relationships[0].to, "注文");
        assert_eq!(diagram.relationships[0].label.as_deref(), Some("places"));
        assert_eq!(
            diagram.relationships[0].from_cardinality,
            mermaid_text::er::Cardinality::ExactlyOne
        );
        assert_eq!(
            diagram.relationships[0].to_cardinality,
            mermaid_text::er::Cardinality::ZeroOrMany
        );
        assert_eq!(
            diagram.relationships[0].line_style,
            mermaid_text::er::LineStyle::Identifying
        );
    }
}
