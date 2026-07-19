using System.Reflection;
using Microsoft.AspNetCore.Diagnostics;
using Shelfarr.Libation.Companion;
using Shelfarr.Libation.Companion.Jobs;
using Shelfarr.Libation.Companion.Libation;
using Shelfarr.Libation.Companion.Security;

if (CompanionHealthProbe.IsRequested(args))
{
    Environment.ExitCode = await CompanionHealthProbe.RunAsync();
    return;
}

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 64 * 1024);
builder.Logging.AddSimpleConsole(options =>
{
    options.SingleLine = true;
    options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ ";
    options.UseUtcTimestamp = true;
});
// The backup route contains the owned title's ASIN. Keep application and
// framework warnings/errors, but do not copy request paths into retained
// container logs at the default Information level.
builder.Logging.AddFilter("Microsoft.AspNetCore.Hosting.Diagnostics", LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.Routing.EndpointMiddleware", LogLevel.Warning);

var companionOptions = CompanionOptions.FromEnvironment();
companionOptions.EnsureDirectories();
builder.Services.AddSingleton(companionOptions);
builder.Services.AddSingleton<TokenFileAuthenticator>();
builder.Services.AddSingleton<CliCoordinator>();
builder.Services.AddSingleton<AuthSessionManager>();
builder.Services.AddSingleton<LibraryCache>();
builder.Services.AddSingleton<OutputFileLocator>();
builder.Services.AddSingleton<JobStore>();
builder.Services.AddSingleton<JobQueue>();
builder.Services.AddHostedService<JobWorker>();

var app = builder.Build();

// Create and permission the shared bearer token before reporting healthy so
// Shelfarr can read it immediately after both containers start.
_ = app.Services.GetRequiredService<TokenFileAuthenticator>();

app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    app.Logger.LogError("Unhandled companion request failure: {ExceptionType}", exception?.GetType().Name ?? "unknown");
    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
    await context.Response.WriteAsJsonAsync(new
    {
        error = "The Libation companion could not process this request."
    });
}));

app.Use(async (context, next) =>
{
    if (context.Request.Path.Equals("/health"))
    {
        await next(context);
        return;
    }

    var authenticator = context.RequestServices.GetRequiredService<TokenFileAuthenticator>();
    if (!authenticator.IsAuthorized(context.Request.Headers.Authorization.ToString()))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        context.Response.Headers.WWWAuthenticate = "Bearer";
        await context.Response.WriteAsJsonAsync(new { error = "A valid companion bearer token is required." });
        return;
    }

    await next(context);
});

app.MapGet("/health", (LibraryCache library, CliCoordinator cli) => Results.Ok(new
{
    status = "ok",
    apiVersion = CompanionOptions.ApiVersion,
    companionVersion = Version(),
    libationVersion = CompanionOptions.PinnedLibationVersion,
    libraryReady = library.Exists,
    busy = cli.IsBusy
}));

app.MapGet("/version", () => Results.Ok(new
{
    apiVersion = CompanionOptions.ApiVersion,
    companionVersion = Version(),
    libationVersion = CompanionOptions.PinnedLibationVersion,
    poweredBy = "Libation",
    upstream = "https://github.com/rmcrackan/Libation"
}));

app.MapGet("/v1/accounts", async (CliCoordinator cli, CompanionOptions options, CancellationToken cancellationToken) =>
{
    try
    {
        var lease = await cli.TryAcquireAsync(cancellationToken);
        if (lease is null)
            return Results.Conflict(new { error = "Libation is already processing another operation." });

        await using (lease)
        {
            var result = await lease.RunAsync(["list-accounts", "--bare"], options.ShortCliTimeout, cancellationToken);
            if (result.ExitCode != 0)
                return Results.Json(new { error = $"Libation account lookup failed with exit code {result.ExitCode}." }, statusCode: 502);

            var accounts = result.StandardOutput
                .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(ParseAccount)
                .Where(account => account is not null)
                .Cast<AccountStatus>()
                .ToArray();
            return Results.Ok(new { accounts });
        }
    }
    catch (TimeoutException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: 504);
    }
    catch (OperationCanceledException)
    {
        return Results.StatusCode(499);
    }
});

app.MapPost("/v1/auth/start", async (
    AuthStartRequest request,
    AuthSessionManager sessions,
    CancellationToken cancellationToken) =>
{
    if (!InputValidation.TryAccount(request.Account, out var account))
        return Results.BadRequest(new { error = "A valid Audible account email is required." });
    if (!InputValidation.TryLocale(request.Locale, out var locale))
        return Results.BadRequest(new
        {
            error = "Unsupported Audible marketplace locale.",
            supported = new[] { "us", "uk", "australia", "canada", "france", "germany", "india", "italy", "japan", "spain" }
        });

    try
    {
        return Results.Ok(await sessions.StartAsync(account, locale, cancellationToken));
    }
    catch (CompanionBusyException exception)
    {
        return Results.Conflict(new { error = exception.Message });
    }
    catch (TimeoutException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: 504);
    }
    catch (InvalidOperationException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: 502);
    }
});

app.MapPost("/v1/auth/complete", async (
    AuthCompleteRequest request,
    AuthSessionManager sessions,
    CancellationToken cancellationToken) =>
{
    if (!Guid.TryParseExact(request.SessionId, "N", out _))
        return Results.BadRequest(new { error = "A valid authentication session ID is required." });
    if (string.IsNullOrWhiteSpace(request.ResponseUrl))
        return Results.BadRequest(new { error = "The final browser response URL is required." });

    try
    {
        var result = await sessions.CompleteAsync(request.SessionId!, request.ResponseUrl, cancellationToken);
        return result is null
            ? Results.NotFound(new { error = "The authentication session is missing or expired." })
            : Results.Ok(result);
    }
    catch (ArgumentException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
    catch (TimeoutException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: 504);
    }
    catch (InvalidOperationException exception)
    {
        return Results.UnprocessableEntity(new { error = exception.Message });
    }
});

app.MapPost("/v1/sync", async Task<IResult> (JobQueue queue, CancellationToken cancellationToken) =>
{
    try
    {
        var result = await queue.EnqueueAsync(CompanionJobKind.Sync, null, cancellationToken);
        return Results.Accepted($"/v1/jobs/{result.Job.Id}", new { job = result.Job, created = result.Created });
    }
    catch (JobCapacityExceededException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: StatusCodes.Status429TooManyRequests);
    }
});

app.MapGet("/v1/library", async Task<IResult> (
    int? offset,
    int? limit,
    LibraryCache library,
    CancellationToken cancellationToken) =>
{
    if (offset is null && limit is null)
    {
        return library.Exists
            ? Results.File(library.OpenRead(), "application/json")
            : Results.NotFound(new { error = "The Audible library has not been synced yet." });
    }

    var pageOffset = offset ?? 0;
    var pageLimit = limit ?? LibraryCache.DefaultPageSize;
    if (pageOffset < 0 || pageLimit is < 1 or > LibraryCache.MaximumPageSize)
    {
        return Results.BadRequest(new
        {
            error = $"Library pages require a non-negative offset and a limit between 1 and {LibraryCache.MaximumPageSize}."
        });
    }

    var page = await library.ReadPageAsync(pageOffset, pageLimit, cancellationToken);
    return page is null
        ? Results.NotFound(new { error = "The Audible library has not been synced yet." })
        : Results.Ok(page);
});

app.MapPost("/v1/backups/{asin}", async Task<IResult> (
    string asin,
    JobQueue queue,
    LibraryCache library,
    CancellationToken cancellationToken) =>
{
    if (!InputValidation.TryAsin(asin, out asin))
        return Results.BadRequest(new { error = "A valid 10-character Audible ASIN is required." });

    try
    {
        _ = await library.RequirePurchasedActiveTitleAsync(asin, cancellationToken);
        var result = await queue.EnqueueAsync(CompanionJobKind.Backup, asin, cancellationToken);
        return Results.Accepted($"/v1/jobs/{result.Job.Id}", new { job = result.Job, created = result.Created });
    }
    catch (JobCapacityExceededException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: StatusCodes.Status429TooManyRequests);
    }
    catch (BackupNotEligibleException exception)
    {
        return Results.UnprocessableEntity(new { error = exception.Message });
    }
});

app.MapGet("/v1/jobs/{id}", (string id, JobStore jobs) =>
{
    if (!Guid.TryParseExact(id, "N", out _))
        return Results.BadRequest(new { error = "A valid job ID is required." });

    var job = jobs.Get(id);
    return job is null
        ? Results.NotFound(new { error = "The companion job was not found." })
        : Results.Ok(job);
});

app.Run();

static string Version()
{
    var informational = Assembly.GetExecutingAssembly()
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
        .InformationalVersion;
    if (!string.IsNullOrWhiteSpace(informational))
        return informational.Split('+', 2)[0];

    return Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "unknown";
}

static AccountStatus? ParseAccount(string line)
{
    var fields = line.Split('\t');
    return fields.Length == 5
        ? new AccountStatus(
            fields[0],
            fields[1],
            fields[2],
            fields[3].Equals("yes", StringComparison.OrdinalIgnoreCase),
            fields[4].Equals("yes", StringComparison.OrdinalIgnoreCase))
        : null;
}

public partial class Program { }
