-- The classes are now warrior, hunter and mage. Existing characters carry over: ranger and rogue become hunters, cleric becomes a mage.
-- (Their saved skill picks, if any, are left alone: the game server only offers skills from the class's current list.)
update characters set class = 'hunter' where class in ('ranger', 'rogue');
update characters set class = 'mage' where class = 'cleric';
