import XCTest
@testable import Pills

final class APIErrorTests: XCTestCase {

    // MARK: - errorDescription

    func testErrorDescription_invalidResponse() {
        let error = APIError.invalidResponse
        XCTAssertEqual(error.errorDescription, "服务器响应异常，请稍后重试")
    }

    func testErrorDescription_networkUnavailable() {
        let error = APIError.networkUnavailable
        XCTAssertEqual(error.errorDescription, "网络连接不可用，请检查网络设置")
    }

    func testErrorDescription_timeout() {
        let error = APIError.timeout
        XCTAssertEqual(error.errorDescription, "请求超时，请检查网络后重试")
    }

    func testErrorDescription_unknown() {
        let error = APIError.unknown
        XCTAssertEqual(error.errorDescription, "发生未知错误，请稍后重试")
    }

    func testErrorDescription_http401() {
        let error = APIError.httpError(statusCode: 401, body: "unauthorized")
        XCTAssertEqual(error.errorDescription, "登录已过期，请重新登录")
    }

    func testErrorDescription_http403() {
        let error = APIError.httpError(statusCode: 403, body: "forbidden")
        XCTAssertEqual(error.errorDescription, "没有权限执行此操作")
    }

    func testErrorDescription_http404() {
        let error = APIError.httpError(statusCode: 404, body: "not found")
        XCTAssertEqual(error.errorDescription, "请求的资源不存在")
    }

    func testErrorDescription_http429() {
        let error = APIError.httpError(statusCode: 429, body: "too many")
        XCTAssertEqual(error.errorDescription, "请求太频繁，请稍后再试")
    }

    func testErrorDescription_http500() {
        let error = APIError.httpError(statusCode: 500, body: "internal")
        XCTAssertEqual(error.errorDescription, "服务器暂时不可用，请稍后重试")
    }

    func testErrorDescription_http503() {
        let error = APIError.httpError(statusCode: 503, body: "unavailable")
        XCTAssertEqual(error.errorDescription, "服务器暂时不可用，请稍后重试")
    }

    func testErrorDescription_httpGeneric() {
        let error = APIError.httpError(statusCode: 418, body: "teapot")
        XCTAssertEqual(error.errorDescription, "请求失败 (418)")
    }

    func testErrorDescription_decodingFailed() {
        let error = APIError.decodingFailed("bad format")
        XCTAssertEqual(error.errorDescription, "数据解析失败：bad format")
    }

    // MARK: - isRetryable

    func testIsRetryable_networkUnavailable() {
        XCTAssertTrue(APIError.networkUnavailable.isRetryable)
    }

    func testIsRetryable_timeout() {
        XCTAssertTrue(APIError.timeout.isRetryable)
    }

    func testIsRetryable_http500() {
        XCTAssertTrue(APIError.httpError(statusCode: 500, body: "").isRetryable)
    }

    func testIsRetryable_http502() {
        XCTAssertTrue(APIError.httpError(statusCode: 502, body: "").isRetryable)
    }

    func testIsRetryable_http429() {
        XCTAssertTrue(APIError.httpError(statusCode: 429, body: "").isRetryable)
    }

    func testIsRetryable_http401_notRetryable() {
        XCTAssertFalse(APIError.httpError(statusCode: 401, body: "").isRetryable)
    }

    func testIsRetryable_http404_notRetryable() {
        XCTAssertFalse(APIError.httpError(statusCode: 404, body: "").isRetryable)
    }

    func testIsRetryable_invalidResponse_notRetryable() {
        XCTAssertFalse(APIError.invalidResponse.isRetryable)
    }

    func testIsRetryable_unknown_notRetryable() {
        XCTAssertFalse(APIError.unknown.isRetryable)
    }

    // MARK: - from()

    func testFrom_passesThroughAPIError() {
        let original = APIError.timeout
        let result = APIError.from(original)
        if case .timeout = result {} else {
            XCTFail("Expected .timeout, got \(result)")
        }
    }

    func testFrom_urlError_notConnectedToInternet() {
        let urlError = URLError(.notConnectedToInternet)
        let result = APIError.from(urlError)
        if case .networkUnavailable = result {} else {
            XCTFail("Expected .networkUnavailable, got \(result)")
        }
    }

    func testFrom_urlError_timedOut() {
        let urlError = URLError(.timedOut)
        let result = APIError.from(urlError)
        if case .timeout = result {} else {
            XCTFail("Expected .timeout, got \(result)")
        }
    }

    func testFrom_urlError_cannotFindHost() {
        let urlError = URLError(.cannotFindHost)
        let result = APIError.from(urlError)
        if case .networkUnavailable = result {} else {
            XCTFail("Expected .networkUnavailable, got \(result)")
        }
    }

    func testFrom_urlError_dnsLookupFailed() {
        let urlError = URLError(.dnsLookupFailed)
        let result = APIError.from(urlError)
        if case .networkUnavailable = result {} else {
            XCTFail("Expected .networkUnavailable, got \(result)")
        }
    }

    func testFrom_urlError_unknownCode() {
        let urlError = URLError(.cancelled)
        let result = APIError.from(urlError)
        if case .unknown = result {} else {
            XCTFail("Expected .unknown, got \(result)")
        }
    }

    func testFrom_genericError() {
        let genericError = NSError(domain: "test", code: 42)
        let result = APIError.from(genericError)
        if case .unknown = result {} else {
            XCTFail("Expected .unknown, got \(result)")
        }
    }
}
