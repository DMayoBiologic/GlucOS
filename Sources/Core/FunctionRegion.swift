import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Supabase runs an edge function in the region nearest the caller: Sydney, for a phone in Perth.
// The GlucOS database is in Mumbai, so every query the relay made from Sydney crossed the Indian
// Ocean, a dozen times for one status read. That put /v1/status at 3 s typically and 10 s at worst,
// close enough to the 15 s timeout that a slow wake-up on the phone tipped it over. Asking for the
// function to run in the database's own region leaves one long hop (phone to Mumbai) per request.
// See https://supabase.com/docs/guides/functions/regional-invocation.

public enum FunctionRegion {
    /// The built-in Supabase project, and the region its database lives in.
    public static let projectHost = "aqlbadbyjuoruwnwyfrc.supabase.co"
    public static let databaseRegion = "ap-south-1"
    public static let header = "x-region"

    /// The region to run a function in for `url`: only for the built-in project, since a relay the
    /// owner hosts elsewhere has its own database somewhere else.
    public static func region(for url: URL?) -> String? {
        url?.host?.lowercased() == projectHost ? databaseRegion : nil
    }

    /// Pins `request` to the database's region when it's for the built-in project.
    public static func pin(_ request: inout URLRequest) {
        if let r = region(for: request.url) { request.setValue(r, forHTTPHeaderField: header) }
    }
}
