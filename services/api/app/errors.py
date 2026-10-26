class RepoError(Exception):
    pass


class NotFound(RepoError):
    pass


class Forbidden(RepoError):
    pass


class Conflict(RepoError):
    pass


class Invalid(RepoError):
    pass


class Locked(RepoError):
    """The account is held by another live login."""
