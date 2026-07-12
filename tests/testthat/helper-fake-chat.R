FakeEllmerChat <- R6::R6Class(
    "FakeEllmerChat",
    inherit = getFromNamespace("Chat", "ellmer"),
    public = list(
        initialize = function(responder, model = "fake",
                              params = list(temperature = 0, seed = 123L,
                                            max_tokens = 128L),
                              system_prompt = "supplied base prompt") {
            if (!is.function(responder)) stop("responder must be a function")
            private$responder <- responder
            provider <- getFromNamespace("test_provider", "ellmer")(
                name = "test", model = model, base_url = "mock://",
                params = params)
            super$initialize(
                provider = provider, system_prompt = system_prompt, echo = "none")
        },
        chat_structured = function(..., type, echo = "none", convert = TRUE) {
            inputs <- list(...)
            prompt <- paste(vapply(
                inputs, function(x) paste(as.character(x), collapse = ""),
                character(1)), collapse = "\n")
            private$responder(prompt, type, self$get_system_prompt())
        }),
    private = list(responder = NULL))

fake_chat <- function(responder, ...) {
    FakeEllmerChat$new(responder = responder, ...)
}
