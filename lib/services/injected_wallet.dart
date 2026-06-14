// Conditional export: real implementation on web (window.ethereum), a stub
// everywhere else. Lets the rest of the app call InjectedWallet without
// worrying about the platform.
export 'injected_wallet_stub.dart'
    if (dart.library.js_interop) 'injected_wallet_web.dart';
