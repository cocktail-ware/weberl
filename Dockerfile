FROM erlang:29.1.2

ENV LANG=C.UTF-8

WORKDIR /app

# Verify Erlang and rebar3 are available
RUN erl -noshell -eval \
    'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' \
    && rebar3 version

# Copy the application
COPY . .

# Start the Erlang application
CMD ["rebar3", "shell"]
