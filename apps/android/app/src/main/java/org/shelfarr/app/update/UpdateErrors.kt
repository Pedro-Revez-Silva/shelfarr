package org.shelfarr.app.update

/** Why an update step stopped, in terms of what the person can do about it. */
enum class UpdateProblem {
    /** No connection, or the publisher couldn't be reached. Retrying may help. */
    OFFLINE,

    /** The publisher answered with an error status. Retrying later may help. */
    SERVER,

    /** The feed is malformed or announces something this build won't accept. */
    BAD_FEED,

    /** The feed or file is for a different app. */
    WRONG_APP,

    /** A URL or redirect would leave the trusted origin and directory. Nothing was fetched there. */
    UNTRUSTED_LOCATION,

    /** The file is larger than announced or allowed. */
    TOO_LARGE,

    /** The file ended early. */
    INCOMPLETE,

    /** The file's checksum doesn't match the feed. */
    CHECKSUM,

    /** The file isn't the announced app, version or publisher. */
    IDENTITY,

    /** Not enough space, or the file couldn't be written. */
    STORAGE,

    /** This device can't run the update. */
    INCOMPATIBLE,

    /** Android refused or failed the installation. */
    INSTALL_FAILED,
}

class UpdateException(
    val problem: UpdateProblem,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    /** Retrying the same step later could succeed without anything changing here. */
    val isTransient: Boolean get() = problem == UpdateProblem.OFFLINE || problem == UpdateProblem.SERVER
}
