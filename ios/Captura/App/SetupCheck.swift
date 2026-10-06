// Stops a signed iPhone build that has no personal settings yet.
//
// Without ios/Config/Captura.local.xcconfig the app is signed with the repository's
// placeholder bundle ID (or the example file's), which can be taken or use up one of a
// free account's App IDs, and the app could only say "Falta configurar Google".
// Captura.base.xcconfig turns the bundle ID and the team into compilation conditions.
// `CAPTURA_TEAM_` alone means no team: simulator builds and the unsigned device compile
// (`CODE_SIGNING_ALLOWED=NO`) never stop here.
#if os(iOS) && !targetEnvironment(simulator) && !CAPTURA_TEAM_ && (CAPTURA_BUNDLE_org_example_captura || CAPTURA_BUNDLE_com_example_captura)
#error("Captura has no settings for this Mac yet, so the app would be signed with a placeholder bundle ID. Quit Xcode, do steps 4 and 5 of docs/ios.md (python3 ios/scripts/configure.py), then open the project and build again.")
#endif
