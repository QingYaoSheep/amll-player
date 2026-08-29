enum LoadableState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(AppError)
}
