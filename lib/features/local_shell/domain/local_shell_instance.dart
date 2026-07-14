class LocalShellInstance {
  const LocalShellInstance({
    required this.id,
    required this.distroId,
    required this.name,
  });

  final String id;
  final String distroId;
  final String name;

  LocalShellInstance copyWith({String? name}) =>
      LocalShellInstance(id: id, distroId: distroId, name: name ?? this.name);
}
