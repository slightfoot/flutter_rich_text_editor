class Task {
  const Task({
    required this.id,
    required this.checked,
    required this.text,
  });

  final String id;
  final bool checked;
  final String text;

  Task copyWith({
    String? id,
    bool? checked,
    String? text,
    int? indent,
  }) {
    return Task(
      id: id ?? this.id,
      checked: checked ?? this.checked,
      text: text ?? this.text,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Task &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          checked == other.checked &&
          text == other.text;

  @override
  int get hashCode => id.hashCode ^ checked.hashCode ^ text.hashCode;
}
