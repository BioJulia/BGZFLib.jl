## Running tests
Use `JULIA_TEST_FAILFAST=true` to prevent your context window being flooded by hundreds of failing tests:
```
JULIA_TEST_FAILFAST=true julia --startup=no --project -e 'using Pkg; Pkg.test()'
```

Avoid comments where the purpose can easily be inferred from the code and variable names themselves.
Otherwise, please do add comments. Approximately comment every 5-10 lines as a loose guideline.
Keep tests small and self-contained. Do not make long chains of tests that mutate the same state, unless it's necessary for the test logic.
When developing this package, you might want check the API of BufferIO.jl, which is probably
downloaded locally since it's a dependency.
When making edits, format with `runic -i .`. If not installed, alert the user that the call failed,
and do not attempt to install Runic.
